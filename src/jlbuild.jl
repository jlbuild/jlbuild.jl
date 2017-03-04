__precompile__()
module jlbuild
import GitHub
using HTTP, JSON
export run_server, JLBuildCommand, NukeJob, BuildJob, CodeJob, binaryrecord,
       dbload, dbsave, verify_gitsha, parse_commands, normalize_gitsha,
       builder_filter, builder_name, builder_suffixes, get_status,
       update_status, nuke_jobs, build_jobs, code_jobs, get_resource

include("logging.jl")
include("models/jobcommon.jl")
include("models/binaryrecord.jl")
include("models/buildjob.jl")
include("models/codejob.jl")
include("models/nukejob.jl")
include("models/jlbuildcommand.jl")
include("buildbot_api.jl")
include("parsing.jl")
include("server.jl")
include("database.jl")

# These must be overridden via environment variables
GITHUB_AUTH_TOKEN = ""
GITHUB_WEBHOOK_SECRET = ""
MYSQL_USER = ""
MYSQL_PASSWORD = ""
MYSQL_HOST = ""

# Try to bring in the environment variables, but don't throw a fit if they're
# not available; we WILL throw a fit if they're not there at run_server() time
check_environment()
end # module jlbuild
