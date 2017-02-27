
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

function update_julia_repo()
    repo = get_julia_repo()

    # update repo
    log("Fetching new julia commits...")
    LibGit2.fetch(repo)

    log("Julia checkout updated.")
    return repo
end

function normalize_gitsha(gitsha::AbstractString)
    # First, lookup this gitsha in the repo
    repo = get_julia_repo()
    git_commit = LibGit2.get(LibGit2.GitCommit, repo, gitsha)

    if git_commit === nothing
        throw(ArgumentError("gitsha $gitsha was not found in the repository"))
    end

    return hex(LibGit2.Oid(git_commit))
end

function verify_gitsha(cmd::JLBuildCommand; auto_update::Bool = true)
    return verify_gitsha(cmd.gitsha; auto_update=auto_update)
end

function verify_gitsha(gitsha::AbstractString; auto_update::Bool = true)
    # First, open the repo (or create if it doesn't already exist)
    repo = get_julia_repo()

    if !LibGit2.iscommit(gitsha, repo)
        # If at first we didn't find this as a commit, try updating if we allow
        # it.  (By default true, disable for testing and other such purposes)
        if auto_update
            update_julia_repo()
            return LibGit2.iscommit(gitsha, repo)
        end

        # auto_update was disabled, and we didn't find it the first time
        return false
    end

    # we found it, yay!
    return true
end

function verify_sender(event)
    username = get(event.sender.login)
    if username == "jlbuild"
        log("Ignoring self-made comment")
        return false
    end

    # Check that this user has JuliaLang-level ownership
    if !any(x -> get(x.login) == "JuliaLang", GitHub.orgs(event.sender)[1])
        log("User $username does not have JuliaLang priviliges")
        return false
    end

    return true
end

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

function get_event_body(event::GitHub.WebhookEvent)
    try
        return event.payload["comment"]["body"]
    end
    try
        return event.payload["pull_request"]["body"]
    end
    log("could not get comment body from event of type $(get_event_type(event))")
    return ""
end

function parse_commands(event::GitHub.WebhookEvent)
    # Grab the gitsha that this PR/review/whatever defaults to
    default_commit = get_event_sha(event)
    log("  Got default_commit of $default_commit")
    body = get_event_body(event)
    cmds = parse_commands(body; default_commit=default_commit)
    for cmd in cmds
        cmd.repo_name = get(event.repository.full_name)
        cmd.comment_place = string(get_event_place(event))
        cmd.comment_type = get_event_type(event)
    end
    return cmds
end

function parse_commands(body::AbstractString; default_commit="")
    commands = JLBuildCommand[]

    # Build regex to find commands embedded in a comment body
    regex = ""

    # Start by finding a line that starts with `@jlbuild`, maybe with whitespace
    regex *= "^\\s*\\@jlbuild"

    # Build a capture group to find a gitsha immediately after `@jlbuild`. The
    # gitsha can be enclosed within backticks, and the whole thing is optional.
    regex *= "(?:[ \\t]+`?([0-9a-fA-F]+)`?)?"

    # Build a group to find all tags that start with `!`
    regex *= "((?:[ \\t]+![^\\s]+)*)"

    # Build a group to find code blocks
    regex *= "\\s*(?:```(?:julia)?(.*?)```)?\$"

    for m in eachmatch(Regex(regex, "ms"), body)
        # Initialize options to defaults
        gitsha = default_commit
        should_nuke = false
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
                elseif startswith(tag, "filter=") && length(tag) > 8
                    builder_filter = tag[8:end]
                end
            end
        end

        # Finally, parse out the code block if it exists
        if m.captures[3] != nothing
            code_block = strip(m.captures[3])
        end

        # Only add this guy if he doesn't already exist in the list of commands
        new_cmd = JLBuildCommand(gitsha=gitsha, code=code_block; should_nuke = should_nuke,
                                 builder_filter = builder_filter)
        if isempty(filter(x -> x == new_cmd, commands))
            push!(commands, new_cmd)
        end
    end

    return commands
end
