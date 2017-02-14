# This is how we authenticate to buildbot through GitHub:
using HTTP
using JSON

client = HTTP.Client()
function buildbot_login()
    global client
    params = Dict("token" => GITHUB_AUTH)
    res = HTTP.get(client, "https://buildtest.e.ip.saba.us/auth/login", query=params)
    if res.status != 200
        throw(ArgumentError("Buildbot login endpoint returned HTTP code $(res.status)"))
    end
    return nothing
end

julia_builder_ids = Dict{Int64,String}()
function list_forceschedulers()
    global client, julia_builder_ids
    res = HTTP.get(client, "https://buildtest.e.ip.saba.us/api/v2/forceschedulers")
    if res.status != 200
        throw(ArgumentError("forceschedulers listing returned HTTP code $(res.status)"))
    end
    data = JSON.parse(readstring(res.body))["forceschedulers"]

    # We only want the force_julia_package builder names
    builder_names = first(z["builder_names"] for z in data if z["name"] == "force_julia_package")
    
    # Now, find the builder ids that match those names
    res = HTTP.get(client, "https://buildtest.e.ip.saba.us/api/v2/builders")
    if res.status != 200
        throw(ArgumentError("builders listing returned HTTP code $(res.status)"))
    end
    data = JSON.parse(readstring(res.body))["builders"]
    empty!(julia_builder_ids)
    for z in data
        if z["name"] in builder_names
            julia_builder_ids[z["builderid"]] = z["name"]
        end
    end
    return nothing
end

immutable BuildbotJob
    builder::String
    builder_id::Int64
    job_id::Int64
end

function start_build(revision)
    global client
    if isempty(julia_builder_ids)
        list_forceschedulers()
    end

    job_list = BuildbotJob[]
    for builder_id in julia_builder_ids
        data = JSON.json(Dict(
            "id" => 1,
            "method" => "force",
            "jsonrpc" => "2.0",
            "params" => Dict(
                "revision" => revision,
                "builderid" => builder_id,
            ),
        ))
        res = HTTP.post(client, "https://buildtest.e.ip.saba.us/api/v2/forceschedulers/force_julia_package"; body=data)
        if res.status != 200
            println(res)
            throw(ArgumentError("force_julia_package returned HTTP code $(res.status)"))
        end
        job_id = JSON.parse(readstring(res.body))["result"][1]
        push!(job_list, BuildbotJob(julia_builder_ids[builder_id], builder_id, job_id))
    end
    return job_list
end

# Just go ahead and login now
buildbot_login()
