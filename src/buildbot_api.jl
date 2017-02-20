import Base: showerror

# Common buildbot things
const buildbot_base = "https://buildtest.e.ip.saba.us"
const download_base = "https://julialang.s3.amazonaws.com/julianightlies_test/bin/latest"
const client = HTTP.Client()
type BuildbotLoginError <: Exception end
function showerror(io::IO, e::BuildbotLoginError)
    print(io, "Access denied from $buildbot_base/auth/login")
end

type HTTPError <: Exception
    method::String
    url::String
    code::Int64
end

function showerror(io::IO, e::HTTPError)
    print(io, "$(e.method) $(e.url) returned $(e.code)")
end


# This get's the given url and returns it, or throws an error
function get_or_die(url, login_retry=false; kwargs...)
    global client
    res = HTTP.get(client, url; kwargs...)
    if res.status != 200
        # Always login and retry once if we're unauthorized
        if res.status == 403
            if login_retry
                throw(BuildbotLoginError())
            end
            buildbot_login()
            return get_or_die(url, true; kwargs...)
        end
        url_short = url[length(buildbot_base)+1:end]
        throw(HTTPError("GET", url_short, res.status))
    end
    return res
end

# This is how we authenticate to buildbot through GitHub
function buildbot_login()
    global GITHUB_AUTH_TOKEN
    params = Dict("token" => GITHUB_AUTH_TOKEN)
    log("Authenticating to buildbot...")
    get_or_die("$buildbot_base/auth/login", true; query=params)
    return nothing
end

const julia_builder_ids = Dict{Int64,String}()
function list_forceschedulers!()
    global julia_builder_ids

    # Get the force_julia_package builder names
    res = get_or_die("$buildbot_base/api/v2/forceschedulers")
    data = JSON.parse(readstring(res.body))["forceschedulers"]
    builder_names = first(z["builder_names"] for z in data if z["name"] == "force_julia_package")

    # Now, find the builder ids that match those names
    res = get_or_die("$buildbot_base/api/v2/builders")
    data = JSON.parse(readstring(res.body))["builders"]
    empty!(julia_builder_ids)
    for z in data
        if z["name"] in builder_names
            julia_builder_ids[z["builderid"]] = z["name"]
        end
    end
    return nothing
end


const force_url = "$buildbot_base/api/v2/forceschedulers/force_julia_package"
"""
`submit_buildcommand!(cmd::JLBuildCommand)`

Given a `JLBuildCommand`, submit it to the buildbot and create a bunch of job
objects tracking the state of each builder's work.  These will be stored within
`cmd.jobs`.

If `cmd.jobs` already exists, it will be heartlessly overwritten with no regard
for the jobs that already existed.
"""
function submit_buildcommand!(cmd::JLBuildCommand)
    global force_url

    # initialize the list of builder ids we're interested in every time.  We
    # don't want to fall behind the times if the buildbot topology changes.
    list_forceschedulers!()

    job_list = BuildbotJob[]
    for builder_id in keys(julia_builder_ids)
        data = JSON.json(Dict(
            "id" => 1,
            "method" => "force",
            "jsonrpc" => "2.0",
            "params" => Dict(
                "revision" => cmd.gitsha,
                "builderid" => builder_id,
            ),
        ))

        res = HTTP.post(client, force_url; body=data)
        job_id = JSON.parse(readstring(res.body))["result"][1]
        gitsha = normalize_gitsha(cmd.gitsha)
        push!(job_list, BuildbotJob(cmd.gitsha, builder_id, job_id, false))
    end

    cmd.jobs = job_list
    cmd.submitted = true

    # Save out this command after updating it
    dbsave(cmd)
    return cmd
end
