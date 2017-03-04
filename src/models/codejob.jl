type CodeJob
    # Linkage to JLBC
    gitsha::String
    comment_id::Int64

    # Who we're running on, what we're gonna run, etc...
    builder_id::Int64
    buildrequest_id::Int64
    code::String
    done::Bool
end

function CodeJob(;gitsha="", comment_id=0, builder_id=0, buildrequest_id=0,
                  code="", done=false)
    return CodeJob(gitsha, comment_id, builder_id, buildrequest_id, code, done)
end

function create_schema(::Type{CodeJob})
    return """
        gitsha CHAR(40) NOT NULL,
        comment_id INT NOT NULL,
        builder_id INT NOT NULL,
        buildrequest_id INT NOT NULL,
        code TEXT NOT NULL,
        done BOOLEAN NOT NULL,
        PRIMARY KEY (gitsha, comment_id, builder_id),
        CONSTRAINT fk_code_cmd FOREIGN KEY (gitsha, comment_id) REFERENCES JLBuildCommand (gitsha, comment_id)
    """
end

function sql_fields(::Type{CodeJob})
    return (
        :gitsha,
        :comment_id,
        :builder_id,
        :buildrequest_id,
        :code,
        :done,
    )
end
