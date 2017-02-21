# This describes a single buildbot job.
type BuildbotJob
    gitsha::String
    builder_id::Int64
    buildrequest_id::Int64
    done::Bool
end

function BuildbotJob(gitsha::AbstractString, builder_id::Int64, buildrequest_id::Int64)
    return BuildbotJob(gitsha, builder_id, buildrequest_id, false)
end

"""
`builder_name(job::BuildbotJob)``

Return the name of the builder running this job.
"""
function builder_name(job::BuildbotJob)
    global julia_builder_ids
    if isempty(julia_builder_ids)
        list_forceschedulers!()
    end
    return julia_builder_ids[job.builder_id]
end

"""
`buildbot_job_url(job::BuildbotJob, data::Dict)`

Return the URL to this buildbot job (if build is pending this throws, so don't.)
"""
function build_url(job::BuildbotJob, data::Dict)
    global buildbot_base
    return "$buildbot_base/#/builders/$(job.builder_id)/builds/$(data["number"])"
end

function buildrequest_url(job::BuildbotJob)
    global buildbot_base
    return "$buildbot_base/#/buildrequests/$(job.buildrequest_id)"
end

"""
`build_download_url(data::Dict)`

Constructs the Amazon S3 download url from buildrequest data
"""
function build_download_url(data::Dict)
    global download_base
    props = Dict(k=>data["properties"][k][1] for k in keys(data["properties"]))

    propkeys = ["os_name", "up_arch", "upload_filename"]
    if !all(haskey(props, key) for key in propkeys)
        return ""
    end

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
    params = Dict(
        "property" => "*",
        "buildrequestid" => string(job.buildrequest_id)
    )
    res = get_or_die("$buildbot_base/api/v2/builds"; query=params)
    builds = JSON.parse(readstring(res.body))["builds"]
    if isempty(builds)
        return Dict(
            "status" => "pending",
            "result" => -1,
            "build_url" => buildrequest_url(job),
            "download_url" => "",
            "start_time" => 0,
        )
    end

    data = builds[1]
    return Dict(
        "status" => ifelse(data["complete"], "complete", "building"),
        "result" => data["results"],
        "build_url" => build_url(job, data),
        "download_url" => build_download_url(data),
        "start_time" => data["started_at"],
    )
end
