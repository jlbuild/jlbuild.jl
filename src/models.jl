import Base: ==

immutable JLBuildCommand
    gitsha::String
    code::String
end
JLBuildCommand(gitsha::AbstractString) = JLBuildCommand(gitsha, "")

function ==(x::JLBuildCommand, y::JLBuildCommand)
    return x.gitsha == y.gitsha && x.code == y.code
end
