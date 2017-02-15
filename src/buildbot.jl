using HTTP
using JSON
import Base: showerror

const buildbot_base = "https://buildtest.e.ip.saba.us"
const download_base = "https://julialang.s3.amazonaws.com/julianightlies_test/bin/latest"
const client = HTTP.Client()
type BuildbotLoginError <: Exception end
function showerror(io::IO, e::BuildbotLoginError)
    print(io, "Logging in to $buildbot_base didn't work")
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
    params = Dict("token" => GITHUB_AUTH)
    get_or_die("$buildbot_base/auth/login", true; query=params)
    return nothing
end

julia_builder_ids = Dict{Int64,String}()
function list_forceschedulers()
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

# This describes a single buildbot job.
immutable BuildbotJob
    gitsha::String
    builder_id::Int64
    job_id::Int64
end

function name(job::BuildbotJob)
    global julia_builder_ids
    return julia_builder_ids[job.builder_id]
end

function buildbot_job_url(job::BuildbotJob)
    return "$buildbot_base/#/builders/$(job.builder_id)/builds/$(job.job_id)"
end

function build_download_url(data)
    props = Dict(k=>data["properties"][k][1] for k in keys(data["properties"]))
    println(props)

    os = props["os_name"]
    up_arch = props["up_arch"]
    filename = props["upload_filename"]
    return "$download_base/$os/$up_arch/$filename"
end

function status(job::BuildbotJob)
    url = "$buildbot_base/api/v2/builders/$(job.builder_id)/builds/$(job.job_id)"
    try
        res = get_or_die(url; query=Dict("property" => "*"))

        data = JSON.parse(readstring(res.body))["builds"][1]
        download_url = ""
        if data["complete"]
            status = "complete"
            # Grab download url from the properties
            download_url = build_download_url(data)
        else
            status = "building"
        end

        return Dict(
            "status" => status,
            "build_url" => buildbot_job_url(job),
            "download_url" => download_url,
            "start_time" => data["started_at"],
        )
    catch e
        if typeof(e) <: HTTPError && e.code == 404
            return Dict(
                "status" => "pending",
                "url" => "",
                "start_time" => 0,
            )
        else
            rethrow(e)
        end
    end
end

# Revision goes in, list of buildbot jobs come out
function start_build(revision)
    buildbot_login()

    const force_url = "$buildbot_base/api/v2/forceschedulers/force_julia_package"
    if isempty(julia_builder_ids)
        list_forceschedulers()
    end

    job_list = BuildbotJob[]
    for builder_id in keys(julia_builder_ids)
        data = JSON.json(Dict(
            "id" => 1,
            "method" => "force",
            "jsonrpc" => "2.0",
            "params" => Dict(
                "revision" => revision,
                "builderid" => builder_id,
            ),
        ))

        res = HTTP.post(client, force_url; body=data)
        job_id = JSON.parse(readstring(res.body))["result"][1]
        gitsha = normalize_gitsha(revision)
        push!(job_list, BuildbotJob(gitsha, builder_id, job_id))
    end
    return job_list
end
