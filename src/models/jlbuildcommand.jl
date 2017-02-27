using DataFrames
import Base: ==

type JLBuildCommand
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
    should_nuke::Bool

    # This is not SQL-serializeable, we have to recreate it
    jobs::Vector{BuildbotJob}
end

# Provide kwargs and non-kwargs version with all defaults
function JLBuildCommand(;gitsha="", code="", submitted = false, repo_name = "",
                         comment_id = 0, comment_place = "unknown",
                         comment_type = :unknown, comment_url = "",
                         builder_filter = "", should_nuke = false,
                         jobs = BuildbotJob[])
    # Construct the object
    return JLBuildCommand(gitsha, code, submitted, repo_name, comment_id,
                          comment_place, comment_type, comment_url,
                          builder_filter, should_nuke, jobs)
end

# Special constructor for testing
function JLBuildCommand(gitsha, code)
    return JLBuildCommand(gitsha=gitsha, code=code)
end

# Helper function to load the JLBC that belongs to a particular BuildbotJob
function JLBuildCommand(job::BuildbotJob)
    return dbload(JLBuildCommand; gitsha=job.gitsha, comment_id=job.comment_id)[1]
end

function ==(x::JLBuildCommand, y::JLBuildCommand)
    return x.gitsha == y.gitsha && x.code == y.code
end

function builder_filter(cmd::JLBuildCommand, builders)
    if isempty(cmd.builder_filter)
        return builders
    end
    filters = split(cmd.builder_filter, ",")
    return filter(b -> any(contains(builder_name(b), f) for f in filters), builders)
end
