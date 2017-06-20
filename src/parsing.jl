"""
`get_julia_repo()`

Return the `GitRepo` object that corresponds to our local Julia checkout.
"""
function get_julia_repo()
    # We maintain a julia repo in ../deps
    const julia_url = "https://github.com/JuliaLang/julia.git"
    const julia_repo_path = abspath(joinpath(@__FILE__,"../../deps/julia"))

    # Clone afresh if it doesn't exist
    if !isdir(julia_repo_path)
        log("Cloning julia to $julia_repo_path...")
        LibGit2.clone(julia_url, julia_repo_path; isbare=true)
    end
    return LibGit2.GitRepo(julia_repo_path)
end


"""
`update_julia_repo()`

Update the local Julia repository cache with new commits.
"""
function update_julia_repo()
    repo = get_julia_repo()

    # update repo
    log("Fetching new julia commits...")
    LibGit2.fetch(repo)

    log("Julia checkout updated.")
    return repo
end

"""
`get_git_commit(obj)`

Given a git object (either a partial gitsha or a tag name) return the
corresponding `GitCommit`` object according to the main Julia repository.
"""
function get_git_commit(obj::AbstractString)
    repo = get_julia_repo()

    # Check to see if this is already a commit
    git_commit = LibGit2.get(LibGit2.GitCommit, repo, obj)
    if git_commit != nothing
        return git_commit
    end

    # Next, see if it's a tag
    try
        tagref = LibGit2.GitReference(repo, "refs/tags/$(obj)")
        return LibGit2.peel(LibGit2.GitCommit, tagref)
    end
    
    throw(ArgumentError("git object $obj was not found in the repository"))
end

"""
`normalize_gitsha(obj)`

Given a partial `gitsha` or git tag, return the full `gitsha` according to the
main Julia repository.
"""
function normalize_gitsha(obj::AbstractString)
    return hex(LibGit2.Oid(get_git_commit(obj)))
end

"""
`short_gitsha(gitsha)`

Given a valid `gitsha`, return the shortest unambiguous prefix of the `gitsha`.
"""
function short_gitsha(gitsha::AbstractString)
    repo = get_julia_repo()

    # Wow this is so hacky.  We depend on the functionality that LibGit2.get()
    # fails out if the given gitsha is ambiguous, so we probe lengths starting
    # at a length of 7 up to the full gitsha length
    for len in 7:length(gitsha)
        try
            LibGit2.get(LibGit2.GitCommit, repo, gitsha)
            return gitsha[1:len]
        end
    end
end

"""
`get_julia_majmin(gitsha)`

Given a `gitsha`, read the `VERSION` file in the root of the Julia repsitory
at that `gitsha`, returning the major and minor versions as a string.
"""
function get_julia_majmin(gitsha::AbstractString)
    # <3 @simonbyrne is the best <3
    repo = get_julia_repo()
    blob = LibGit2.GitBlob(LibGit2.revparse(repo, "$gitsha:VERSION").ptr)
    v = VersionNumber(unsafe_string(convert(Ptr{UInt8}, LibGit2.content(blob))))

    return "$(v.major).$(v.minor)"
end

"""
`verify_gitsha(cmd; auto_update = true)`

Given a JLBuildCommand `cmd`, verify that the gitsha within `cmd` is valid.
"""
function verify_gitsha(cmd::JLBuildCommand; auto_update::Bool = true)
    return verify_gitsha(cmd.gitsha; auto_update=auto_update)
end

"""
`verify_gitsha(obj; auto_update = true)`

Given a git object `obj`, verify that it is valid.
"""
function verify_gitsha(obj::AbstractString; auto_update::Bool = true)
    try
        get_git_commit(obj)

        # we found it, yay!
        return true
    end

    # If at first we didn't find this as a commit, try updating if we allow
    # it.  (By default true, disable for testing and other such purposes)
    if auto_update
        update_julia_repo()
        return verify_gitsha(obj; auto_update = false)
    end

    # auto_update was disabled, and we didn't find it the first time
    return false
end

"""
`verify_action_type(event)`

Given a GitHub `event`, check to see that the event we're sourcing from is
actually an action we want to deal with, e.g. opening an issue rather than
updating its labels, etc...
"""
function verify_action_type(event)
    # Certain event kinds are overloaded, we want to pay attention
    # to only certain actions, so gate those here.
    const actions = ["created", "opened"]
    
    return event.payload["action"] in actions
end

"""
`verify_sender(event)`

Given a GitHub `event`, check to see that the instigating user has "JuliaLang"
priviliges and is not `"jlbuild"`, as we don't want to respond to our own
comments/messages.
"""
function verify_sender(event)
    username = get(event.sender.login)
    if username == "jlbuild"
        return false
    end

    # Check that this user has JuliaLang-level ownership
    if !any(x -> get(x.login) == "JuliaLang", GitHub.orgs(event.sender)[1])
        log("User $username does not have JuliaLang priviliges")
        return false
    end

    return true
end

"""
`get_event_type(event)`

Given a GitHub `event`, return the type of the event such as pull request,
issue, issue comment, etc...
"""
function get_event_type(event::GitHub.WebhookEvent)
    if event.kind == "commit_comment"
        return :commit
    elseif event.kind == "pull_request_review_comment"
        return :review
    elseif event.kind == "pull_request"
        return :pr
    elseif event.kind == "issue_comment"
        return :pr
    elseif event.kind == "issues"
        return :pr
    end
    return :unknown
end

"""
`get_event_sha(event)`

Given a GitHub `event`, return the gitsha of the event.
"""
function get_event_sha(event::GitHub.WebhookEvent)
    global github_auth
    try
        return event.payload["comment"]["commit_id"]
    end
    try
        return event.payload["pull_request"]["head"]["sha"]
    end
    try
        issue_number = event.payload["issue"]["number"]
        pr = GitHub.pull_request(event.repository, issue_number, auth=github_auth)
        return get(get(pr.head).sha)
    end
    log("Couldn't get gitsha from event of type $(get_event_type(event))")
    return ""
end

"""
`get_event_place(event)`

Given a GitHub `event`, return the "place" of the event, such as the PR number,
issue number, etc...
"""
function get_event_place(event::GitHub.WebhookEvent)
    try
        return event.payload["pull_request"]["number"]
    end
    try
        return event.payload["issue"]["number"]
    end
    try
        return get_event_sha(event)
    end
end

"""
`get_event_body(event)`

Given a GitHub `event`, return the body of the comment/issue/pr, etc...
"""
function get_event_body(event::GitHub.WebhookEvent)
    try
        return event.payload["comment"]["body"]
    end
    try
        return event.payload["pull_request"]["body"]
    end
    try
        return event.payload["issue"]["body"]
    end
    log("could not get comment body from event of type $(get_event_type(event))")
    return ""
end

"""
`parse_commands(event)`

Given a GitHub `event`, analyze its content and metadata to extract all given
commands, inferring commit to build if none is given.
"""
function parse_commands(event::GitHub.WebhookEvent)
    # Grab the gitsha that this PR/review/whatever defaults to
    default_commit = get_event_sha(event)
    body = get_event_body(event)
    cmds = parse_commands(body; default_commit=default_commit)
    for cmd in cmds
        cmd.repo_name = get(event.repository.full_name)
        cmd.comment_place = string(get_event_place(event))
        cmd.comment_type = get_event_type(event)
    end
    return cmds
end

"""
`parse_commands(body; default_commit="")`

Given a comment `body` and an optional `default_commit`, extract all `@jlbuild`
commands and return them as `JLBuildCommand` objects.
"""
function parse_commands(body::AbstractString; default_commit="")
    commands = JLBuildCommand[]

    # Build regex to find commands embedded in a comment body
    regex = ""

    # Start by finding a line that starts with `@jlbuild`
    regex *= "^\\s*\\@jlbuild"

    # Build a capture group to find a gitsha or tag immediately after
    # `@jlbuild`. The gitsha can be enclosed within backticks, and the whole
    # thing is optional.
    regex *= "(?:[ \\t]+`?([0-9a-zA-Z\-\./]+)`?)?"

    # Build a group to find all tags that start with `!`
    regex *= "((?:[ \\t]+![^\\s]+)*)"

    # Build a group to find code blocks
    regex *= "\\s*(?:```(?:julia)?(.*?)```)?\$"

    for m in eachmatch(Regex(regex, "ms"), body)
        # Initialize options to defaults
        gitsha = default_commit
        should_nuke = false
        force_rebuild = false
        extra_make_flags = ""
        builder_filter = ""
        code_block = ""

        # If there's no gitsha capture, no biggie, use the default_commit passed
        # in to us from scraping github.  If that doesn't exist, ignore this.
        if m.captures[1] != nothing
            gitsha = m.captures[1]
        end

        # Early exit if we can't find a gitsha and we have no default gitsha
        if isempty(gitsha)
            continue
        end

        # Next let's split up all the tags into their own strings
        if m.captures[2] != nothing
            tag_regex = r"!([\S]+)"
            tags = [z.captures[1] for z in eachmatch(tag_regex, m.captures[2])]

            # Parse out any tags we're interested in
            for tag in tags
                if tag == "nuke"
                    should_nuke = true
                elseif tag == "rebuild"
                    force_rebuild = true
                elseif startswith(tag, "flags=") && length(tag) > 7
                    extra_make_flags = tag[7:end]
                elseif startswith(tag, "filter=") && length(tag) > 8
                    builder_filter = tag[8:end]
                end
            end
        end

        # Finally, parse out the code block if it exists
        if m.captures[3] != nothing
            code_block = strip(m.captures[3])
        end

        # Add the built command here
        push!(commands, JLBuildCommand(;
            gitsha = gitsha,
            code = code_block,
            should_nuke = should_nuke,
            force_rebuild = force_rebuild,
            builder_filter = builder_filter,
            extra_make_flags = extra_make_flags,
        ))
    end

    return commands
end
