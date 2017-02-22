#__precompile__()
module jlbuild
import GitHub
using HTTP, JSON
export run_server, JLBuildCommand, BuildbotJob, dbload, dbsave, verify_gitsha,
        parse_commands

include("logging.jl")
include("models/buildbotjob.jl")
include("models/jlbuildcommand.jl")
include("buildbot_api.jl")
include("parsing.jl")
include("server.jl")
include("database.jl")

GITHUB_AUTH_TOKEN = ""
GITHUB_WEBHOOK_SECRET = ""
MYSQL_USER = "root"
MYSQL_PASSWORD = "sqlpassword123"
MYSQL_HOST = "127.0.0.1"
function __init__()
    # Grab secret stuff from the environment
    env_list = [:GITHUB_AUTH_TOKEN, :GITHUB_WEBHOOK_SECRET, :MYSQL_USER, :MYSQL_PASSWORD, :MYSQL_HOST]
    for name in env_list
        @eval begin
            global $name
            $name = get(ENV, $(string(name)), $name)

            if isempty($name)
                error($("Must provide $(join(env_list, ", ")) as environment variables, but $(name) was empty"))
            end
        end
    end
end
end # module jlbuild
