using HttpCommon

function build_eventloop()
    # We run forever
    while true
        # Sleep 15 seconds each iteration
        sleep(15)

        # Find any JLBC's that haven't been submitted to the buildbot at all
        new_jobs = dbload(JLBuildCommand; submitted=false)
        for idx in 1:length(new_jobs)
            log("Submitting build $(new_jobs[idx])")
            submit_buildcommand!(new_jobs[idx])
        end

        # Find any BuildbotJob's that aren't completed
        pending_jobs = dbload(BuildbotJob; done=false)
        for idx in 1:length(pending_jobs)
            log("Pending job: $(pending_jobs[idx])")
        end
    end
end

function queue_build(cmd::JLBuildCommand; login_retry=false)
    try
        submit_buildcommand!(cmd)
        dbsave(cmd)
    catch
        log("Unable to submit to buildbot!  Hopefully I'll retry eventually...")
    end
end

function reply_comment(cmd::JLBuildCommand, msg::AbstractString)
    global github_auth
    params = Dict("body" => strip(msg))
    GitHub.create_comment( GitHub.repo(cmd.repo_name), cmd.comment_place,
                           cmd.comment_type, auth=github_auth, params=params)
end

# function reply_comment(event::GitHub.WebhookEvent, msg::AbstractString)
#     global github_auth
#     comment_place = get_comment_place(event)
#     comment_type = get_comment_type(event)
#     GitHub.create_comment( event.repository, comment_place, comment_type;
#                            auth=github_auth, params = Dict("body" => strip(msg)))
# end

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
        for cmd in commands
            # Save them to the DB.
            dbsave(cmd)

            reply_comment(cmd, """
                Got it, building $(cmd.gitsha)

                I will edit this comment as the build jobs complete.
            """)
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
