import Base: showerror

# Common buildbot things
const buildbot_base = "https://buildtest.e.ip.saba.us"
const download_base = "https://julianightlies.s3.amazonaws.com"
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
function http_or_die(method, uri, login_retry=0; kwargs...)
    global client
    res = HTTP.request(client, method, uri; kwargs...)
    if res.status != 200
        # Always login and retry a few times if we're unauthorized, because the
        # HTTP.jl <--> buildbot channel is ridiculously flaky. I don't know why.
        if res.status == 403
            if login_retry > 3
                throw(BuildbotLoginError())
            end
            buildbot_login()
            return http_or_die(method, uri, login_retry + 1; kwargs...)
        end
        throw(HTTPError(method, uri, res.status))
    end
    return res
end

function get_or_die(url; query="", kwargs...)
    return http_or_die("GET", HTTP.URI(url; query=query); kwargs...)
end
function post_or_die(url; kwargs...)
    return http_or_die("POST", HTTP.URI(url); kwargs...)
end


# This is how we authenticate to buildbot through GitHub
function buildbot_login()
    global GITHUB_AUTH_TOKEN
    params = Dict("token" => GITHUB_AUTH_TOKEN)
    log("Authenticating to buildbot...")
    get_or_die("$buildbot_base/auth/login"; query=params)
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
        if z["name"] in builder_names && startswith(z["name"], "package_")
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

        res = post_or_die(force_url; body=data)
        buildrequest_id = JSON.parse(readstring(res.body))["result"][1]
        job = BuildbotJob(cmd.gitsha, builder_id, buildrequest_id, cmd.comment_id)
        push!(job_list, job)
        dbsave(job)
        log("Initiated build of $(cmd.gitsha[1:10]) on $(builder_name(job))")
    end

    cmd.jobs = job_list
    cmd.submitted = true

    # Save out this command after updating it
    dbsave(cmd)
    return cmd
end
