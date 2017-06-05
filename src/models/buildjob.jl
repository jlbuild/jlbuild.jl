immutable BuildJob
    # Linkage to JLBC
    gitsha::String
    comment_id::Int64

    # Who we're building on
    builder_id::Int64
    buildrequest_id::Int64
    done::Bool
end

function BuildJob(;gitsha="", comment_id=0, builder_id = 0, buildrequest_id = 0,
                   done = false)
    # Construct the object
    return BuildJob(gitsha, comment_id, builder_id, buildrequest_id, done)
end

function show(io::IO, x::BuildJob)
    sha = short_gitsha(x.gitsha)
    show(io, "BuildJob($sha, $(builder_name(x)), $(x.buildrequest_id))")
end



function create_schema(::Type{BuildJob})
    return """
        gitsha CHAR(40) NOT NULL,
        comment_id INT NOT NULL,
        builder_id INT NOT NULL,
        buildrequest_id INT NOT NULL,
        done BOOLEAN NOT NULL,
        PRIMARY KEY (gitsha, comment_id, builder_id),
        CONSTRAINT fk_build_cmd FOREIGN KEY (gitsha, comment_id) REFERENCES JLBuildCommand (gitsha, comment_id)
    """
end

function sql_fields(::Type{BuildJob})
    return (
        :gitsha,
        :comment_id,
        :builder_id,
        :buildrequest_id,
        :done,
    )
end

function get_status(job::BuildJob)
    status = get_status(job.buildrequest_id)
    if status["status"] == "complete"
        # We add in the download_url for this guy if he's complete. :)
        status["download_url"] = download_url(status["data"])
    end
    return status
end
