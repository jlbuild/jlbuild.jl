# This describes a single buildbot job.
immutable BuildbotJob
    gitsha::String
    builder_id::Int64
    job_id::Int64
    done::Bool
end

"""
`builder_name(job::BuildbotJob)``

Return the name of the builder running this job.
"""
function builder_name(job::BuildbotJob)
    global julia_builder_ids
    return julia_builder_ids[job.builder_id]
end

"""
`buildbot_job_url(job::BuildbotJob)`

Return the URL to this buildbot job (if build is pending, this URL is invalid)
"""
function buildbot_job_url(job::BuildbotJob)
    global buildbot_base
    return "$buildbot_base/#/builders/$(job.builder_id)/builds/$(job.job_id)"
end

"""
`build_download_url(data::Dict)`

Constructs the Amazon S3 download url from
"""
function build_download_url(data::Dict)
    global download_base
    props = Dict(k=>data["properties"][k][1] for k in keys(data["properties"]))
    println(props)

    os = props["os_name"]
    up_arch = props["up_arch"]
    filename = props["upload_filename"]
    return "$download_base/$os/$up_arch/$filename"
end

"""
`status(job::BuildbotJob)`

Return a dictionary summarizing the status of this buildbot job. Contains useful
information such as `"status"`, which is one of `"complete"`, `"building"`, or
`"pending"`. `"build_url"` which points `buildbot_job_url()` if status is not
`"pending"`, and similar for `"download_url"`.
"""
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
