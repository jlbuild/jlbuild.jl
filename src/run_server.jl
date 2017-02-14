include("jlbuild.jl")
include("secret.jl")
include("buildbot.jl")


build_queue = Dict{JLBuildCommand, Vector{BuildbotJob}}()
function queue_build(cmd::JLBuildCommand; login_retry=false)
    try
        job_list = start_build(cmd.gitsha)
    catch
        if !login_retry
            buildbot_login()
            return queue_build(cmd; login_retry=true)
        end
    end

    build_queue[cmd] = job_list
end


function reply_comment(event::GitHub.WebhookEvent, msg::AbstractString)
    comment_place = get_comment_place(event)
    comment_type = get_comment_type(event)
    GitHub.create_comment( event.repository, comment_place, comment_type;
                           auth=auth, params = Dict("body" => strip(msg)))
end

event_ = nothing
function callback(event::GitHub.WebhookEvent)
    log("callback!")
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
            queue_build(cmd)

            reply_comment(event, """
            Got it, building $(cmd.gitsha)

            I will edit this comment once the build jobs are complete.
            """)
        end
    end

    return HttpCommon.Response(202, "I gotcha boss")
end


auth = GitHub.authenticate(GITHUB_AUTH)
repos = ["JuliaLang/julia", "jlbuild/jlbuild.jl"]
events = ["commit_comment","pull_request","pull_request_review_comment","issues","issue_comment"]
listener = GitHub.EventListener(callback; events=events, auth=auth, secret=WEBHOOK_SECRET, repos=repos)
@schedule run(listener, 7050)
