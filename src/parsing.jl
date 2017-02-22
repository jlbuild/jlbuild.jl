
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

function get_comment_type(event::GitHub.WebhookEvent)
    if event.kind == "commit_comment"
        return :commit
    elseif event.kind == "pull_request_review_comment"
        return :review
    elseif event.kind == "pull_request"
        return :pr
    elseif event.kind == "issue_comment"
        return :pr
    end
    return :unknown
end

function get_comment_sha(event::GitHub.WebhookEvent)
    try
        return event.payload["comment"]["commit_id"]
    end
    try
        return event.payload["pull_request"]["head"]["sha"]
    end
    log("Couldn't get gitsha from event of type $(get_comment_type(event))")
    return ""
end

function get_comment_place(event::GitHub.WebhookEvent)
    try
        return event.payload["pull_request"]["number"]
    end
    try
        return event.payload["issue"]["number"]
    end
    try
        return get_comment_sha(event)
    end
end

function parse_commands(event::GitHub.WebhookEvent)
    # Grab the gitsha that this PR/review/whatever defaults to
    default_commit = get_comment_sha(event)
    log("  Got default_commit of $default_commit")
    body = event.payload["comment"]["body"]
    cmds = parse_commands(body; default_commit=default_commit)
    for cmd in cmds
        cmd.repo_name = get(event.repository.full_name)
        cmd.comment_place = string(get_comment_place(event))
        cmd.comment_type = get_comment_type(event)
    end
    return cmds
end

function parse_commands(body::AbstractString; default_commit="")
    commands = JLBuildCommand[]

    # We automatically attempt to figure out what gitsha the user wants built.
    # First, we see if there's an overriding gitsha given via @jlbuild <gitsha>
    for m in eachmatch(r"^\s*\@jlbuild( +`?([0-9a-fA-F]+)`?)?"m, body)
        if m.captures[2] != nothing
            gitsha = m.captures[2]
        else
            gitsha = default_commit
        end

        if isempty(gitsha)
            continue
        end

        # Let's see if there's a code block after this
        code_block = ""
        after_body = body[m.offset + length(m.match):end]
        code_match = match(r"\s*```(julia)?(.*?)```"s, after_body)
        if code_match != nothing
            code_block = strip(code_match.captures[2])
        end

        # Only add this guy if he doesn't already exist in the list of commands
        if isempty(filter(x -> x.gitsha == gitsha, commands))
            push!(commands,JLBuildCommand(normalize_gitsha(gitsha), code_block))
        end
    end

    return commands
end
