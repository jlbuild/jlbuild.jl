using DataFrames
import Base: ==

type JLBuildCommand
    gitsha::String
    code::String
    submitted::Bool
    repo_name::String
    comment_place::String
    comment_type::Symbol

    # This is not SQL-serializeable, we have to recreate it
    jobs::Vector{BuildbotJob}
end

function JLBuildCommand(gitsha::AbstractString, code::NAtype)
    return JLBuildCommand(gitsha, "", false, "", "unknown", :unknown, BuildbotJob[])
end

function JLBuildCommand(gitsha::AbstractString, code::AbstractString)
    return JLBuildCommand(gitsha, code, false, "", "unknown", :unknown, BuildbotJob[])
end

function JLBuildCommand(gitsha::AbstractString, code::AbstractString, submitted::Bool,
                        repo_name::String, comment_place::String, comment_type::Symbol)
    return JLBuildCommand(gitsha, code, submitted, repo_name, comment_place, comment_type, BuildbotJob[])
end

function ==(x::JLBuildCommand, y::JLBuildCommand)
    return x.gitsha == y.gitsha && x.code == y.code
end
