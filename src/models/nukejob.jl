type NukeJob
    # Linkage to JLBC
    gitsha::String
    comment_id::Int64

    builder_id::Int64
    buildrequest_id::Int64
    done::Bool
end

function NukeJob(;gitsha="", comment_id=0, builder_id=0, buildrequest_id=0,
                  done=false)
    return NukeJob(gitsha, comment_id, builder_id, buildrequest_id, done)
end

function show(io::IO, x::NukeJob)
    sha = short_gitsha(x.gitsha)
    show(io, "NukeJob($sha, $(builder_name(x)), $(x.buildrequest_id))")
end

function create_schema(::Type{NukeJob})
    return """
        gitsha CHAR(40) NOT NULL,
        comment_id INT NOT NULL,
        builder_id INT NOT NULL,
        buildrequest_id INT NOT NULL,
        done BOOL NOT NULL,
        PRIMARY KEY (gitsha, comment_id, builder_id),
        CONSTRAINT fk_nuke_cmd FOREIGN KEY (gitsha, comment_id) REFERENCES JLBuildCommand (gitsha, comment_id)
    """
end

function sql_fields(::Type{NukeJob})
    return (
        :gitsha,
        :comment_id,
        :builder_id,
        :buildrequest_id,
        :done,
    )
end
