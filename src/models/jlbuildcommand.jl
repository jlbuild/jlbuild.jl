import Base: ==

immutable JLBuildCommand
    gitsha::String
    code::String
    submitted::Bool
    repo_name::String
    comment_id::Int64
    comment_place::String
    comment_type::Symbol
    comment_url::String

    # Flags we can set
    builder_filter::String
    extra_make_flags::String
    should_nuke::Bool
    force_rebuild::Bool
end

# Provide kwargs and non-kwargs version with all defaults
function JLBuildCommand(;gitsha="", code="", submitted = false, repo_name = "",
                         comment_id = 0, comment_place = "unknown",
                         comment_type = :unknown, comment_url = "",
                         builder_filter = "", extra_make_flags="",
                         should_nuke = false, force_rebuild = false)
    # Construct the object
    return JLBuildCommand(gitsha, code, submitted, repo_name, comment_id,
                          comment_place, comment_type, comment_url,
                          builder_filter, extra_make_flags, should_nuke,
                          force_rebuild)
end

function show(io::IO, x::JLBuildCommand)
    sha = short_gitsha(x.gitsha)
    code = x.code
    if length(code) > 15
        code = "$(code[1:12])..."
    end
    show(io, "JLBuildCommand($sha, \"$code\", $(x.comment_url))")
end

# Schema for a JLBuildCommand.  Just gitsha and code
function create_schema(::Type{JLBuildCommand})
    return """
        gitsha CHAR(40) NOT NULL,
        code MEDIUMTEXT NOT NULL,
        submitted BOOLEAN NOT NULL,
        repo_name TEXT NOT NULL,
        comment_id INT NOT NULL,
        comment_place TEXT NOT NULL,
        comment_type TEXT NOT NULL,
        comment_url TEXT NOT NULL,
        builder_filter TEXT NOT NULL,
        extra_make_flags TEXT NOT NULL,
        should_nuke BOOLEAN NOT NULL,
        force_rebuild BOOLEAN NOT NULL,
        PRIMARY KEY (gitsha, comment_id)
    """
end

function sql_fields(::Type{JLBuildCommand})
    return (
        :gitsha,
        :code,
        :submitted,
        :repo_name,
        :comment_id,
        :comment_place,
        :comment_type,
        :comment_url,
        :builder_filter,
        :extra_make_flags,
        :should_nuke,
        :force_rebuild,
    )
end

for (name, job_type) in [
    (:nuke, NukeJob),
    (:build, BuildJob),
    (:code, CodeJob)]
    name_jobs = Symbol(name, "_jobs")
    @eval begin
        # Helper function to load all the job types that belong to a JLBC
        function $name_jobs(cmd::JLBuildCommand; verbose=false)
            return dbload($(job_type);
                gitsha = cmd.gitsha,
                comment_id = cmd.comment_id,
                verbose = verbose,
            )
        end

        # Helper function to load the JLBC that belongs to a particular job
        function JLBuildCommand(job::$(job_type); verbose=false)
            return first(dbload(JLBuildCommand;
                gitsha = job.gitsha,
                comment_id = job.comment_id,
                verbose = verbose,
            ))
        end
    end
end


function builder_filter(cmd::JLBuildCommand)
    global build_builder_ids
    if isempty(build_builder_ids)
        list_build_forceschedulers!()
    end

    builder_ids = keys(build_builder_ids)

    if isempty(cmd.builder_filter)
        return builder_ids
    end
    filters = split(cmd.builder_filter, ",")
    bname = builder_id -> build_builder_ids[builder_id]
    return filter(b -> any(contains(bname(b), f) for f in filters), builder_ids)
end

function builder_suffixes(cmd::JLBuildCommand)
    builder_ids = builder_filter(cmd)

    return sort([builder_suffix(build_builder_ids, b) for b in builder_ids])
end

function extra_make_flags(cmd::JLBuildCommand)
    return split(cmd.extra_make_flags, ",")
end

function get_status(cmd::JLBuildCommand)
    # First, get list of builder suffixes
    suffixes = builder_suffixes(cmd)

    # Initialize everything with N/A
    mapping = Dict(
        "nuke" => Dict{String,Any}(
            suffix => Dict("status" => "N/A") for suffix in suffixes
        ),
        "build" => Dict{String,Any}(
            suffix => Dict("status" => "N/A") for suffix in suffixes
        ),
        "code" => Dict{String,Any}(
            suffix => Dict("status" => "N/A") for suffix in suffixes
        ),
    )

    # Next, start pulling out Jobs and matching them to their suffixes
    job_funcs = Dict("nuke"=>nuke_jobs, "build"=>build_jobs, "code"=>code_jobs)
    for job_type in keys(mapping)
        for job in job_funcs[job_type](cmd)
            suffix = builder_suffix(job)
            if !(suffix in suffixes)
                log("Somehow we have a reverse-orphan. $suffix was not in $suffixes.  Panic.")
                continue
            end

            # Fill in the mapping with the latest job status
            mapping[job_type][suffix] = get_status(job)
            mapping[job_type][suffix]["job"] = job
        end
    end

    return mapping
end
