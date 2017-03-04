# This describes a binary we know about and can immediately use for code running
type BinaryRecord
    gitsha::String
    builder_suffix::String
end

function BinaryRecord(;gitsha="", builder_suffix="")
    return BinaryRecord(gitsha, builder_suffix)
end

function create_schema(::Type{BinaryRecord})
    return """
        gitsha CHAR(40) NOT NULL,
        builder_suffix CHAR(20) NOT NULL,
        PRIMARY KEY (gitsha, builder_suffix)
    """
end

function sql_fields(::Type{BinaryRecord})
    return (
        :gitsha,
        :builder_suffix,
    )
end
