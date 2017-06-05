using HttpCommon
using TimeZones

# The lifecycle of the objects defiend within jlbuild are as follows:
#
# Parsing github comments creates JLBuildCommands
# First step:
#  - If a nuke is requested, a NukeJob is created
#  - Otherwise, unless rebuild is forced, we check
# If a build is needed, a BuildJob is created from a JLBC
# Otherwise, a CodeJob is created directly from that JLBC (if we have code)
# and whatever BinaryRecord it was matched with
#
# Every BuildJob that finishes creates a CodeJob (if we have code) matched with
# whatever BinaryRecord we just created


# Github resource caching
repo_cache = Dict{String,GitHub.Repo}()
function get_repo(name::AbstractString)
    global repo_cache, github_auth
    if !haskey(repo_cache, name)
        repo_cache[name] = GitHub.repo(name; auth=github_auth)
    end

    return repo_cache[name]
end

commit_cache = Dict{String,GitHub.Commit}()
function get_commit(gitsha::AbstractString)
    global commit_cache, github_auth
    if !haskey(commit_cache, gitsha)
        commit_cache[gitsha] = GitHub.commit("JuliaLang/julia", gitsha; auth=github_auth)
    end
    return commit_cache[gitsha]
end


run_event_loop = true
function run_eventloop()
    global run_event_loop

    # We run forever, or until someone falsifies run_event_loop
    while run_event_loop
        # Find any JLBC's that haven't been submitted to the buildbot at all
        new_cmds = dbload(JLBuildCommand; submitted=false)
        for idx in 1:length(new_cmds)
            log("Submitting build $(new_cmds[idx])")
            submit_jlbc!(new_cmds[idx])
        end

        # Find any nuke/build/code jobs that aren't completed yet
        pending_jobs = vcat(
            dbload(NukeJob; done=false),
            dbload(BuildJob; done=false),
            dbload(CodeJob; done=false),
        )
        for job in pending_jobs
            # Check to see if the job is actually done
            status = update_status!(job)

            if job.done && !(status in ["errored", "canceled"])
                # If we just finished, move this on to the next stage
                log("Progressing $(job)")
                submit_next_job!(job)
            end
        end

        # Helper function that gives us the parameters to search for a JLBC with
        # We first uniquify these dicts, then use those to hit the DB for our
        # unique set of JLBCs
        cmd_refify = j -> Dict(:gitsha => j.gitsha, :comment_id => j.comment_id)
        for cmd_ref in unique(cmd_refify(j) for j in pending_jobs)
            # Update the comments for all JLBuildCommand's whose jobs have had
            # activity.  We do this down here so that we don't waste time and
            # rate limited resources updating the comment of a JLBC twice.
            cmd = dbload(JLBuildCommand; cmd_ref...)[1]
            update_comment(cmd)
        end

        # Sleep a bit each iteration, so we're not a huge CPU/network hog
        sleep(15)
    end
end

function comment!(cmd::JLBuildCommand, msg::AbstractString)
    global github_auth
    try
        if cmd.comment_id == 0
            comment = GitHub.create_comment(
                get_repo(cmd.repo_name),
                cmd.comment_place,
                cmd.comment_type,
                auth = github_auth,
                params = Dict("body" => strip(msg))
            )
            cmd.comment_id = get(comment.id)
            cmd.comment_url = string(get(comment.html_url))
            log("Creating comment $(cmd.comment_url)")
        else
            GitHub.edit_comment(
                get_repo(cmd.repo_name),
                cmd.comment_id,
                cmd.comment_type,
                auth = github_auth,
                params = Dict("body" => strip(msg))
            )
            log("Updating comment $(cmd.comment_url)")
        end
    catch
        log("Couldn't create/update comment $(cmd.comment_url)")
    end
end

function send_help_message(event)
    help_message = strip("""
I'm sorry, I couldn't parse out any valid commands from your comment.
Please see my [README](https://github.com/jlbuild/jlbuild.jl) for instructions on how to use me.
    """)
    global github_auth
    GitHub.create_comment(
        event.repository,
        get_event_place(event),
        get_event_type(event),
        auth = github_auth,
        params = Dict("body" => help_message)
    )
end

function time_str(timestamp)
    t = ZonedDateTime(Dates.unix2datetime(timestamp), TimeZone("UTC"))
    t = astimezone(t, TimeZone("America/Los_Angeles"))
    return Dates.format(t, "U dd, HH:MM:SS Z")
end

comment_text_cache = Dict{String,String}()
function update_comment(cmd::JLBuildCommand)
    global comment_text_cache
    if !haskey(comment_text_cache, cmd.comment_url)
        comment_text_cache[cmd.comment_url] = ""
    end

    gitsha_url = get(get_commit(cmd.gitsha).html_url)
    if !cmd.submitted
        msg = "Got it, building $(gitsha_url)\n\n" *
              "I will edit this comment as the build jobs complete."

        if comment_text_cache[cmd.comment_url] != msg
            comment!(cmd, msg)
            comment_text_cache[cmd.comment_url] = msg
            dbsave(cmd)
        end
    else
        msg = "## Status of $(gitsha_url) builds:\n\n"

        # Grab the status dict
        cmd_status = get_status(cmd)

        # First, build a header
        header = "| Builder Name "
        subder = "| :----------- "

        # If we're nuking, include a "Nuke" column
        if cmd.should_nuke
            header *= "| Nuke "
            subder *= "| :--: "
        end

        # We always post a "Build" column
        header *= "| Build "
        subder *= "| :---: "

        # We always post a download column, garnered from BinaryRecords
        header *= "| Download "
        subder *= "| :------: "

        # If we're running code, include a code column
        if !isempty(cmd.code)
            header *= "| Code Output "
            subder *= "| :---------: "
        end

        function output_build_status(status)
            ustat = uppercase(status["status"])
            if ustat != "N/A"
                return "| [$(ustat)]($(status["build_url"])) "
            end
            return "| N/A "
        end

        function output_build_url(status)
            if status["status"] == "complete"
                return "| [Download]($(status["download_url"])) "
            else
                return "| N/A "
            end
        end

        # Slap these onto `msg` as the header, then start outputting the rows
        msg *= header * "|\n" * subder * "|\n"

        for suffix in sort(builder_suffixes(cmd))
            # Output name
            msg = msg * "| $suffix "

            # If we are supposed to nuke, output nuke status
            if cmd.should_nuke
                msg *= output_build_status(cmd_status["nuke"][suffix])
            end

            msg *= output_build_status(cmd_status["build"][suffix])
            # if bstat == "building"
            #     msg = msg * "started at $(time_str(build_stat["start_time"])) "
            # end

            msg *= output_build_url(cmd_status["build"][suffix])

            msg *= output_build_status(cmd_status["code"][suffix])
            msg = msg * "|\n"
        end


        if comment_text_cache[cmd.comment_url] != msg
            comment!(cmd, msg)
            comment_text_cache[cmd.comment_url] = msg
            dbsave(cmd)
        end
    end
end

event_ = nothing
function github_callback(event::GitHub.WebhookEvent)
    # debugging
    global event_, github_auth

    # verify we should be listening to this comment at all
    if !verify_sender(event)
        return HttpCommon.Response(202, "bad sender")
    end

    event_ = event

    # Next, parse out the commands
    commands = parse_commands(event)

    # Filter them on whether they point to valid gitsha's and normalize them
    filt_commands = filter(c -> verify_gitsha(c), commands)
    for cmd in filt_commands
        cmd.gitsha = normalize_gitsha(cmd.gitsha)
    end

    if isempty(filt_commands) && !isempty(commands)
        send_help_message(event)
        return HttpCommon.Response(202, "no valid commands")
    end

    @schedule begin
        # Save each cmd to the db
        for cmd in filt_commands
            log("Launching $(cmd)")
            update_comment(cmd)
        end
    end

    return HttpCommon.Response(202, "I gotcha boss")
end

github_auth = nothing
function github_login()
    global github_auth
    log("Authenticating to GitHub...")
    github_auth = GitHub.authenticate(GITHUB_AUTH_TOKEN)
end

function check_environment(;strict=false)
    # Grab secret stuff from the environment
    env_list = [
        :GITHUB_AUTH_TOKEN,
        :GITHUB_WEBHOOK_SECRET,
        :MYSQL_USER,
        :MYSQL_PASSWORD,
        :MYSQL_HOST
    ]
    for name in env_list
        @eval begin
            global $name
            $name = get(ENV, $(string(name)), $name)

            if isempty($name) && $strict
                error($("Must provide $(join(env_list, ", ")) as environment variables, but $(name) was empty"))
            end
        end
    end
end

event_loop_task = nothing
github_listener_task = nothing
function run_server(port=7050)
    global GITHUB_AUTH_TOKEN, GITHUB_WEBHOOK_SECRET, github_auth
    global event_loop_task, github_listener_task

    # Check the environment, make sure we have all our secrets loaded in
    check_environment(strict=true)

    # Update julia first things first, so that we don't have a huge delay when
    # responding to our first github webhook while we clone down Julia
    update_julia_repo()

    # List forceschedulers to ensure that we have these things already cached
    list_code_forceschedulers!()
    list_nuke_forceschedulers!()
    list_build_forceschedulers!()

    # Login to Github, and let's get these event loops a-rollin'!
    github_login()
    repos = ["JuliaLang/julia", "jlbuild/jlbuild.jl"]
    events = ["commit_comment","pull_request","pull_request_review_comment","issues","issue_comment"]
    listener = GitHub.EventListener(github_callback; events=events, auth=github_auth, secret=GITHUB_WEBHOOK_SECRET, repos=repos)
    github_listener_task = @schedule run(listener, port)
    event_loop_task = @schedule run_eventloop()
end
