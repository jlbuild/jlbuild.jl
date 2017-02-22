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
function build_eventloop()
    global run_event_loop

    # We run forever, or until someone falsifies run_event_loop
    while run_event_loop
        # Find any JLBC's that haven't been submitted to the buildbot at all
        new_cmds = dbload(JLBuildCommand; submitted=false)
        for idx in 1:length(new_cmds)
            log("Submitting build $(new_cmds[idx])")
            submit_buildcommand!(new_cmds[idx])
        end

        # Find any BuildbotJob's that aren't completed
        pending_jobs = dbload(BuildbotJob; done=false)
        unique_gitshas = unique([j.gitsha for j in pending_jobs])
        for gitsha in unique_gitshas
            cmd = dbload(JLBuildCommand; gitsha=gitsha)[1]
            update_comment(cmd)
        end

        # Sleep a bit each iteration, so we're not a huge CPU hog
        sleep(5)
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

        msg = msg * "| Builder Name | Status | Download | Code Output |\n"
        msg = msg * "| :----------- | :----: | :------: | :---------: |\n"
        for job in sort(cmd.jobs, by=j -> builder_name(j))
            name = builder_name(job)
            job_status = status(job)

            # Output name
            msg = msg * "| [$name]($(builder_url(job))) "

            # Output status
            jstat = job_status["status"]
            msg = msg * "| [$jstat]($(uppercase(job_status["build_url"])))"

            if jstat == "building"
                start_time = Libc.strftime(job_status["start_time"])
                msg = msg * ", started at $start_time "
            else
                msg = msg * " "
            end

            if jstat == "complete"
                dl_url = job_status["download_url"]
                msg = msg * "| [Download]($dl_url)! "
            else
                msg = msg * "| N/A "
            end

            msg = msg * "| N/A "

            if jstat in ["canceled", "complete", "errored"]
                # Make sure to flip the job.done bit here so these get out of
                # the pool of jobs that get reprocessed
                job.done = true
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
        return HttpCommon.Response(400, "bad sender")
    end

    # Next, parse out the commands
    commands = parse_commands(event)

    # Filter them on whether they point to valid gitsha's
    commands = filter(c -> verify_gitsha(c), commands)

    if isempty(commands)
        return HttpCommon.Response(400, "no valid commands")
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

function run_server(port=7050)
    global GITHUB_AUTH_TOKEN, GITHUB_WEBHOOK_SECRET, github_auth

    # Login to everything
    buildbot_login()
    github_login()
    db_login()

    repos = ["JuliaLang/julia", "jlbuild/jlbuild.jl"]
    events = ["commit_comment","pull_request","pull_request_review_comment","issues","issue_comment"]
    listener = GitHub.EventListener(callback; events=events, auth=github_auth, secret=GITHUB_WEBHOOK_SECRET, repos=repos)
    @schedule run(listener, port)
    @schedule build_eventloop()
end
