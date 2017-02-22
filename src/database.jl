using MySQL, DataFrames


con = nothing
function db_login()
    global con
    log("Authenticating to mysql...")
    con = mysql_connect("nureha.cs.washington.edu", MYSQL_USER, MYSQL_PASSWORD, "jlbuild")

    # Create our tables if we need to
    create_tables()
end

# Schema for a JLBuildCommand.  Just gitsha and code
function create_schema(::Type{JLBuildCommand})
    return """
        gitsha CHAR(40) NOT NULL,
        code MEDIUMTEXT NOT NULL,
        submitted BOOLEAN NOT NULL,
        repo_name TEXT NOT NULL,
        comment_id INT NOT NULL,
        comment_place TEXT NOT NULL,
        comment_type TEXT NOT NULL,
        comment_url TEXT NOT NULL,
        PRIMARY KEY (gitsha, comment_id)
    """
end

function sql_fields(::Type{JLBuildCommand})
    return (
        :gitsha,
        :code,
        :submitted,
        :repo_name,
        :comment_id,
        :comment_place,
        :comment_type,
        :comment_url,
    )
end

# Schema for a buildbot job.  Has a foreignkey that points to its parent
# JLBuildCommand, pointed to by its gitsha, which just so happens to be the
# primary key of the JLBuildCommand table
function create_schema(::Type{BuildbotJob})
    return """
        gitsha CHAR(40) NOT NULL,
        builder_id INT NOT NULL,
        buildrequest_id INT NOT NULL,
        comment_id INT NOT NULL,
        done BOOLEAN NOT NULL,
        PRIMARY KEY (gitsha, builder_id, buildrequest_id),
        CONSTRAINT fk_cmd FOREIGN KEY (gitsha, comment_id) REFERENCES JLBuildCommand (gitsha, comment_id)
    """
end

function sql_fields(::Type{BuildbotJob})
    return (:gitsha, :builder_id, :buildrequest_id, :comment_id, :done)
end

function table_exists(table_name::AbstractString)
    global con
    result = mysql_execute(con, """
        SELECT *
        FROM information_schema.tables
        WHERE table_schema = 'jlbuild' AND table_name = '$table_name'
        LIMIT 1;
    """)
    return size(result,1) != 0
end

function create_tables()
    global con
    for name in [:JLBuildCommand, :BuildbotJob]
        @eval begin
            if !table_exists($("$name"))
                log($("Creating table $name because it didn't exist before..."))
                cmd = """
                    CREATE TABLE $($name) (
                        $(create_schema($name))
                    )
                """
                mysql_execute(con, cmd)
            end
        end
    end
end

# Strings must be quoted
function dbescape(x::AbstractString)
    global con
    return mysql_escape(con, x)
end
# Bools should get translated to
function dbescape(x::Bool)
    if x
        return '1'
    end
    return '0'
end
dbescape(x) = dbescape(string(x))
String(x::NAtype) = ""


function dbsave{T}(x::T)
    global con
    fields = sql_fields(T)
    values = collect(getfield(x, Symbol(f)) for f in fields)
    values = ("'$(dbescape(value))'" for value in values)
    cmd = strip("""
        SET FOREIGN_KEY_CHECKS=0;
        REPLACE INTO $T ($(join(fields, ", "))) VALUES ($(join(values, ", ")));
        SET FOREIGN_KEY_CHECKS=1;
    """)
    return mysql_execute(con, cmd)
end

function dbload{T}(::Type{T}; kwargs...)
    global con
    fields = sql_fields(T)
    where_list = ["$(kv[1]) = '$(dbescape(kv[2]))'" for kv in kwargs]

    cmd = "SELECT $(join(fields, ", ")) FROM $T"
    if !isempty(where_list)
        cmd = "$cmd WHERE $(join(where_list, ", "));"
    end
    r = mysql_execute(con, cmd)

    # Collect the results from the SQL query, convert into arguments of the type
    # the constructor will expect, then construct objects from each row of r
    result = [T((fieldtype(T,f)(r[i,f]) for f in fields)...) for i in 1:size(r,1)]

    # Because we can't do fancy invoke stuff with keyword arguments on 0.5 in
    # order to override the base behavior of dbload(), just do "manual dispatch"
    if T <: JLBuildCommand
        for idx in 1:length(result)
            result[idx].jobs = dbload(BuildbotJob, gitsha=result[idx].gitsha)
        end
    end

    return result
end
