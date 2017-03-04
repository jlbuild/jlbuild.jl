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
        throw(HTTPError(method, string(uri), res.status))
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

function list_forceschedulers!(mapping::Dict{Int64,String},
                               scheduler_name::AbstractString;
                               name_prefix::AbstractString = "")
    res = get_or_die("$buildbot_base/api/v2/forceschedulers")
    data = JSON.parse(readstring(res.body))["forceschedulers"]
    names = first(z["builder_names"] for z in data if z["name"] == scheduler_name)

    # Now, find the builder ids that match those names
    res = get_or_die("$buildbot_base/api/v2/builders")
    data = JSON.parse(readstring(res.body))["builders"]
    empty!(mapping)
    for z in data
        if z["name"] in names && startswith(z["name"], name_prefix)
            mapping[z["builderid"]] = z["name"]
        end
    end
    return nothing
end

# Generate list_build_forceschedulers!() and friends...
for (name, scheduler_name, name_prefix, job_type) in [
    (:build, "package", "package_", BuildJob),
    (:code, "run_code", "", CodeJob),
    (:nuke, "nuke", "", NukeJob)]
    list_name = Symbol(name, "_builder_ids")
    force_name = Symbol("list_", name, "_forceschedulers!")
    @eval begin
        const $list_name = Dict{Int64,String}()
        function $force_name()
            global $list_name
            list_forceschedulers!($list_name, $scheduler_name;
                                  name_prefix = $name_prefix)
        end

        function builder_name(job::$job_type)
            global $list_name
            if isempty($list_name)
                $force_name()
            end
            return $list_name[job.builder_id]
        end

        function builder_suffix(job::$job_type)
            name = builder_name(job)
            return name[rsearch(name, '_')+1:end]
        end
    end
end

function builder_suffix(list, builder_id)
    name = list[builder_id]
    return name[rsearch(name, '_')+1:end]
end

function matching_builder(new_list, old_list, old_builder_id)
    name_suffix = builder_suffix(old_list, old_builder_id)
    return first(k for (k,v) in new_list if endswith(v, name_suffix))
end


function builder_url(job::BuildJob)
    global buildbot_base
    return "$buildbot_base/#/builders/$(job.builder_id)"
end


"""
`get_resource(resource::AbstractString; kwargs...)`

Gets a Buildbot resource such as "builders" or "buildrequests", passing in the
given keyword arguments as parameters to filter down the results.  Example:

data = get_resource("builders"; buildrequest_id=10)
"""
function get_resource(resource::AbstractString; kwargs...)
    global buildbot_base
    params = Dict{String,Any}("property" => "*")
    for (k, v) in kwargs
        params[string(k)] = v
    end

    res = get_or_die("$buildbot_base/api/v2/$resource"; query=params)
    return JSON.parse(readstring(res.body))[resource]
end

const forcebuild_url = "$buildbot_base/api/v2/forceschedulers/package"
const forcenuke_url = "$buildbot_base/api/v2/forceschedulers/nuke"
const forcecode_url = "$buildbot_base/api/v2/forceschedulers/run_code"

"""
`submit_jlbc!(cmd::JLBuildCommand)`

Given a `JLBuildCommand`, submit it to the buildbot and create a bunch of job
objects tracking the state of each builder's work.
"""
function submit_jlbc!(cmd::JLBuildCommand)
    global forcebuild_url, nuke_builder_ids, build_builder_ids, code_builder_ids

    # initialize the list of builder ids we're interested in every time.  We
    # don't want to fall behind the times if the buildbot topology changes.
    list_build_forceschedulers!()
    if cmd.should_nuke
        list_nuke_forceschedulers!()
    end
    if !isempty(cmd.code)
        list_code_forceschedulers!()
    end

    for builder_id in builder_filter(cmd)
        # If we should nuke before building, put the buildrequest in!
        nuke_buildrequest_id = 0
        if cmd.should_nuke
            nuke_builderid = matching_builder(nuke_builder_ids, build_builder_ids, builder_id)
            submit_nuke!(cmd.gitsha, cmd.comment_id, nuke_builderid)
            continue
        end

        # Check to see if we actually need to build.
        name_suffix = builder_suffix(build_builder_ids, builder_id)
        should_build = cmd.force_rebuild || isempty(dbload(BinaryRecord; gitsha=cmd.gitsha, builder_suffix=name_suffix))

        if should_build
            submit_build!(cmd.gitsha, cmd.comment_id, builder_id)
            continue
        end

        # Lastly, if we've made it this far and we've got code, start it running
        if !isempty(cmd.code)
            code_builderid = matching_builder(code_builder_ids, build_builder_ids, builder_id)
            submit_code!(cmd, code_builderid)
        end
    end

    # Save out this command after updating it
    cmd.submitted = true
    dbsave(cmd)
    return cmd
end

function submit_nuke!(gitsha, comment_id, builder_id)
    global forcenuke_url
    data = JSON.json(Dict(
        "id" => 1,
        "method" => "force",
        "jsonrpc" => "2.0",
        "params" => Dict(
            "builderid" => builder_id,
        ),
    ))

    res = post_or_die(forcenuke_url; body=data)
    buildrequest_id = JSON.parse(readstring(res.body))["result"][1]

    nuke_job = NukeJob(;
        gitsha = gitsha,
        comment_id = comment_id,
        builder_id = builder_id,
        buildrequest_id = buildrequest_id
    )
    dbsave(nuke_job)
    log("Initiated Nuke on $(builder_name(nuke_job))")
end

function submit_build!(gitsha, comment_id, builder_id)
    global forcebuild_url
    data = JSON.json(Dict(
        "id" => 1,
        "method" => "force",
        "jsonrpc" => "2.0",
        "params" => Dict(
            "revision" => gitsha,
            "builderid" => builder_id,
        ),
    ))

    res = post_or_die(forcebuild_url; body=data)
    buildrequest_id = JSON.parse(readstring(res.body))["result"][1]
    build_job = BuildJob(;
        gitsha = gitsha,
        builder_id = builder_id,
        buildrequest_id = buildrequest_id,
        comment_id = comment_id
    )
    dbsave(build_job)
    shortsha = short_gitsha(gitsha)
    log("Initiated build of $shortsha on $(builder_name(build_job))")
end

function submit_code!(cmd::JLBuildCommand, builder_id)
    global forcecode_url

    majmin = get_julia_majmin(cmd.gitsha)
    # Ha. Ha ha.  Ha ha ha ha.  Ohh I was too clever for myself by half.
    #shortcommit = short_gitsha(cmd.gitsha)
    shortcommit = cmd.gitsha[1:10]

    data = JSON.json(Dict(
        "id" => 1,
        "method" => "force",
        "jsonrpc" => "2.0",
        "params" => Dict(
            "builderid" => builder_id,
            "code_block" => cmd.code,
            "majmin" => majmin,
            "shortcommit" => shortcommit,
        ),
    ))
    res = post_or_die(forcecode_url; body=data)

    code_job = CodeJob(;
        gitsha = cmd.gitsha,
        comment_id = cmd.comment_id,
        builder_id = builder_id,
        buildrequest_id = JSON.parse(readstring(res.body))["result"][1],
        code = cmd.code
    )
    dbsave(code_job)
    return code_job
end

function submit_next_job!(job::NukeJob)
    # A Nuke job turns into a Build job, always
    builder_id = matching_builder(build_builder_ids, nuke_builder_ids, job.builder_id)
    submit_build!(job.gitsha, job.comment_id, builder_id)
end

function submit_next_job!(job::BuildJob)
    cmd = JLBuildCommand(job)

    # So we just finished a BuildJob.  Let's wrap this guy up in a BinaryRecord
    # and get on our way
    br = BinaryRecord(gitsha=cmd.gitsha, builder_suffix=builder_suffix(job))
    dbsave(br)

    # A build job turns into a code job if the code is not empty
    if !isempty(cmd.code)
        builder_id = matching_builder(code_builder_ids, build_builder_ids, job.builder_id)
        submit_code!(cmd, builder_id)
    end
end

function submit_next_job!(job::CodeJob)
    # We are all done!!!!
end




"""
`buildrequest_url(buildrequest_id)`

Given the `buildrequest_id`, construct the URL to the actual buildbot page.
"""
function buildrequest_url(buildrequest_id::Int64)
    global buildbot_base
    return "$(buildbot_base)/#/buildrequests/$(buildrequest_id)"
end

"""
`build_url(builder_id, build_number)`

Given the `builder_id` and `build_number` from the JSON payload of a
`buildrequest` response, construct the URL to the actual buildbot build page.
"""
function build_url(builder_id::Int64, build_number::Int64)
    global buildbot_base
    return "$(buildbot_base)/#/builders/$(builder_id)/builds/$(build_number)"
end

"""
`status(buildrequest_id::Int64)`

Return a dictionary summarizing the status of this buildbot job. Contains useful
information such as `"status"`, which is one of `"complete"`, `"building"`,
`"canceled"`, `"pending"` or `"errored"`. `"build_url"` which points
`buildbot_job_url()`, and `"started_at"` if that makes sense for the status.
"""
function get_status(buildrequest_id::Int64)
    builds = get_resource("builds"; buildrequestid=buildrequest_id)
    if isempty(builds)
        # check to make sure that the buildrequest itself wasn't canceled
        try
            data = get_resource("buildrequests"; buildrequestid=buildrequest_id)

            # If data["complete"], then this build was canceled
            if data[1]["complete"]
                return Dict(
                    "status" => "canceled",
                    "result" => 5,
                    "build_url" => buildrequest_url(buildrequest_id),
                    "start_time" => 0,
                    "data" => data,
                )
            end
        end

        # Default is to say it's still pending
        return Dict(
            "status" => "pending",
            "result" => -1,
            "build_url" => buildrequest_url(buildrequest_id),
            "start_time" => 0,
            "data" => builds,
        )
    end

    data = builds[1]
    status_name = ""
    if data["complete"]
        if data["results"] == 0
            # We completed successfully
            status_name = "complete"
        elseif data["results"] == 6
            # The build itself was canceled.  INTERESTING.
            status_name = "canceled"
        else
            # We completed with errors
            status_name = "errored"
        end
    else
        # We are still building
        status_name = "building"
    end

    return Dict(
        "status" => status_name,
        "result" => data["results"],
        "build_url" => build_url(data["builderid"], data["number"]),
        "start_time" => data["started_at"],
        "data" => data,
    )
end

"""
`download_url(data::Dict)`

Constructs the Amazon S3 download url from buildrequest data
"""
function download_url(data::Dict)
    global download_base
    props = Dict(k=>data["properties"][k][1] for k in keys(data["properties"]))

    propkeys = ["os_name", "up_arch", "upload_filename"]
    if !all(haskey(props, key) for key in propkeys)
        return ""
    end

    os = props["os_name"]
    up_arch = props["up_arch"]
    majmin = props["majmin"]
    filename = props["upload_filename"]
    return "$download_base/test/bin/$os/$up_arch/$majmin/$filename"
end
