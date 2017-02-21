using HttpCommon

run_event_loop = true
function build_eventloop()
    global run_event_loop

    last_check = Dict{String,Float64}()

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
            # Only hit the buildbot/update comments every X seconds per gitsha
            if get(last_check, gitsha, 0) + 5*60 < time()
                cmd = dbload(JLBuildCommand; gitsha=gitsha)[1]
                log("Updating comment $(comment_url(cmd))")
                update_comment(cmd)
                last_check[gitsha] = time()
            end
        end

        # Sleep a bit each iteration, so we're not a huge CPU hog
        sleep(5)
    end
end

function comment_url(cmd::JLBuildCommand)
    return string(get(GitHub.comment(cmd.repo_name, cmd.comment_id).html_url))
end

function comment!(cmd::JLBuildCommand, msg::AbstractString)
    global github_auth
    if cmd.comment_id == 0
        comment = GitHub.create_comment(
            GitHub.repo(cmd.repo_name),
            cmd.comment_place,
            cmd.comment_type,
            auth = github_auth,
            params = Dict("body" => strip(msg))
        )
        cmd.comment_id = get(comment.id)
    else
        GitHub.edit_comment(
            GitHub.repo(cmd.repo_name),
            cmd.comment_id,
            cmd.comment_type,
            auth = github_auth,
            params = Dict("body" => strip(msg))
        )
    end
end

function update_comment(cmd::JLBuildCommand)
    if !cmd.submitted
        msg = "Got it, building $(cmd.gitsha)\n\n" *
              "I will edit this comment as the build jobs complete."
        comment!(cmd, msg)
    else
        msg = "Build of $(cmd.gitsha) status:"
        for job in cmd.jobs
            name = builder_name(job)
            job_status = status(job)

            job_msg = "* $name: <a href=\"$(job_status["build_url"])\">$(job_status["status"])"
            if job_status["status"] == "pending"
                job_msg = job_msg * "</a>"
            elseif job_status["status"] == "building"
                start_time = Libc.strftime(job_status["start_time"])
                job_msg = job_msg * "</a>, started at $start_time"
            elseif job_status["status"] == "complete"
                if job_status["result"] == 0
                    dlurl = job_status["download_url"]
                    job_msg = job_msg * " with a build artifact</a>! " *
                                        "<a href=\"$dlurl\">Download link.</a>"
                else
                    job_msg = job_msg * " with errors</a>."
                end

                # Make sure to flip the job.done bit here so these get out of
                # the pool of jobs that get reprocessed
                job.done = true
                dbsave(job)
            end

            msg = msg * "\n\n" * job_msg
        end

        comment!(cmd, msg)
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
            dbsave(cmd)
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

    repos = ["JuliaLang/julia", "jlbuild/jlbuild.jl"]
    events = ["commit_comment","pull_request","pull_request_review_comment","issues","issue_comment"]
    listener = GitHub.EventListener(callback; events=events, auth=github_auth, secret=GITHUB_WEBHOOK_SECRET, repos=repos)
    @schedule run(listener, port)
    @schedule build_eventloop()
end
