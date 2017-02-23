using HttpCommon

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
        # Find any BuildbotJob's that aren't completed, or haven't run their code yet
        pending_code_jobs = dbload(BuildbotJob; done=true, code_run=false, coderun_buildrequest_id=0)
        for job in pending_code_jobs
            submit_coderun!(JLBuildCommand(job), job)
        end

        # Find any JLBC's that haven't been submitted to the buildbot at all
        new_cmds = dbload(JLBuildCommand; submitted=false)
        for idx in 1:length(new_cmds)
            log("Submitting build $(new_cmds[idx])")
            submit_buildcommand!(new_cmds[idx])
        end

        # Find any pending jobs that haven't finished building yet, add that to
        # the list of buildbot jobs that haven't had their code completed yet
        jobs = vcat(dbload(BuildbotJob; done=false), pending_code_jobs)
        cmd_refify = j -> Dict(:gitsha => j.gitsha, :comment_id => j.comment_id)
        for cmd_ref in unique([cmd_refify(j) for j in jobs])
            # Update the comments for all JLBuildCommand's whose jobs have had
            # activity.  We do this down here so that we don't waste time and
            # rate limited resources updating the comment of a JLBC twice.
            update_comment(dbload(JLBuildCommand; cmd_ref...)[1])
        end

        # Sleep a bit each iteration, so we're not a huge CPU hog
        sleep(15)
    end
end

function comment!(cmd::JLBuildCommand, msg::AbstractString)
    global github_auth
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

        msg = msg * "| Builder Name | Build | Download | Code Output |\n"
        msg = msg * "| :----------- | :----: | :------: | :---------: |\n"
        for job in sort(cmd.jobs, by=j -> builder_name(j))
            name = builder_name(job)
            job_status = build_status(job)

            # Output name
            msg = msg * "| [$name]($(builder_url(job))) "

            # Output status
            jstat = job_status["status"]
            cstat = nothing
            msg = msg * "| [$(uppercase(jstat))]($(job_status["build_url"]))"

            # Build "status" column
            if jstat == "building"
                start_time = Libc.strftime(job_status["start_time"])
                msg = msg * ", started at $start_time "
            else
                msg = msg * " "
            end

            # Build download column
            if jstat == "complete"
                dl_url = job_status["download_url"]
                msg = msg * "| [Download]($dl_url) "
            else
                msg = msg * "| N/A "
            end

            # Build "Code Output" column
            if jstat == "complete"
                # Only bother hitting the buildbot for code status if it has
                # already successfully completed building!
                coderun_status = code_status(job)
                cstat = coderun_status["status"]
                msg = msg * "| [$(uppercase(cstat))]($(coderun_status["build_url"]))"
            else
                msg = msg * "| N/A "
            end




            if jstat in ["canceled", "complete", "errored"]
                # Make sure to flip the job.done bit here so these get out of
                # the pool of jobs that get reprocessed
                job.done = true

                # If a job was canceled or errored, say that the code was run
                # as well, so that we don't keep trying to run its code. :(
                if jstat in ["canceled", "errored"] || cstat == "complete"
                    job.code_run = true
                end
                dbsave(job)
            end

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
function callback(event::GitHub.WebhookEvent)
    # debugging
    global event_
    event_ = event

    # verify we should be listening to this comment at all
    if !verify_sender(event)
        return HttpCommon.Response(202, "bad sender")
    end

    # Next, parse out the commands
    commands = parse_commands(event)

    # Filter them on whether they point to valid gitsha's and normalize them
    commands = filter(c -> verify_gitsha(c), commands)
    for cmd in commands
        cmd.gitsha = normalize_gitsha(cmd.gitsha)
    end

    if isempty(commands)
        return HttpCommon.Response(202, "no valid commands")
    end

    @schedule begin
        # Save each cmd to the db
        for cmd in commands
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

event_loop_task = nothing
github_listener_task = nothing
function run_server(port=7050)
    global GITHUB_AUTH_TOKEN, GITHUB_WEBHOOK_SECRET, github_auth
    global event_loop_task, github_listener_task

    github_login()
    repos = ["JuliaLang/julia", "jlbuild/jlbuild.jl"]
    events = ["commit_comment","pull_request","pull_request_review_comment","issues","issue_comment"]
    listener = GitHub.EventListener(callback; events=events, auth=github_auth, secret=GITHUB_WEBHOOK_SECRET, repos=repos)
    github_listener_task = @schedule run(listener, port)
    event_loop_task = @schedule run_eventloop()
end
