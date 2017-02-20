#__precompile__()
module jlbuild
import GitHub
using HTTP, JSON

export run_server, JLBuildCommand, BuildbotJob

include("logging.jl")
include("models/buildbotjob.jl")
include("models/buildcommand.jl")
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

    # Login to everything, in the background
    @schedule begin
        buildbot_login()
        github_login()
        db_login()
    end
end
end # module jlbuild
