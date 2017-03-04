using MySQL, DataFrames # DataFrames for NAType

# This file contains my database management layer.  Types get slapped into their
# own databases, governed by their own create_schema(::Type{T}) functions, and
# are serialized/deserialized through their own sql_fields(::Type{T}) functions.
# Everything else should be pretty much automatic, save objects to the DB with
# dbsave(), query for objects with dbload().  If there is special logic that
# needs to be run after a dbload(), do so within dbload_posthook!(x::T).

db_connection = nothing
function db_login()
    global db_connection
    log("Authenticating to mysql...")
    db_connection = mysql_connect("db", MYSQL_USER, MYSQL_PASSWORD, "jlbuild")

    # Create our tables if we need to
    create_tables()
end

function execute_or_die(command::AbstractString; verbose=false, login_retry = 0)
    global db_connection
    try
        if verbose
            log("Executing SQL query: [$command]")
        end
        return mysql_execute(db_connection, command)
    catch e
        if verbose
            log("  That didn't go well: $(e)")
        end
        # Try logging in
        if login_retry > 3
            rethrow()
        else
            db_login()
            return execute_or_die(command; verbose=verbose, login_retry=login_retry + 1)
        end
    end
end


function table_exists(table_name::AbstractString)
    result = execute_or_die("""
        SELECT *
        FROM information_schema.tables
        WHERE table_schema = 'jlbuild' AND table_name = '$table_name'
        LIMIT 1;
    """)
    return size(result,1) != 0
end

function create_tables()
    for name in [:JLBuildCommand, :NukeJob, :BuildJob, :CodeJob, :BinaryRecord]
        @eval begin
            if !table_exists($("$name"))
                log($("Creating table $name because it didn't exist before..."))
                cmd = """
                    CREATE TABLE $($name) (
                        $(create_schema($name))
                    )
                """
                execute_or_die(cmd; login_retry=10)
            end
        end
    end
end

function moduleless_typename(T)
    # Sigh, this is to work around the problem that if I run code interactively,
    # it prepends the `jlbuild.` module specifier in front of my types.  :(
    return "$T"[rsearch("$T", '.')+1:end]
end

# Strings must be quoted
function dbescape(x::AbstractString)
    global db_connection
    if db_connection == nothing
        db_login()
    end
    return mysql_escape(db_connection, x)
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


function dbsave{T}(x::T; verbose=false)
    fields = sql_fields(T)
    values = collect(getfield(x, Symbol(f)) for f in fields)
    values = ("'$(dbescape(value))'" for value in values)
    cmd = strip("""
        SET FOREIGN_KEY_CHECKS=0;
        REPLACE INTO $(moduleless_typename(T)) ($(join(fields, ", ")))
        VALUES ($(join(values, ", ")));
        SET FOREIGN_KEY_CHECKS=1;
    """)
    return execute_or_die(cmd; verbose=false)
end

function dbload{T}(::Type{T}; verbose=false, kwargs...)
    fields = sql_fields(T)
    where_list = ["$(kv[1]) = '$(dbescape(kv[2]))'" for kv in kwargs]

    cmd = "SELECT $(join(fields, ", ")) FROM $(moduleless_typename(T))"
    if !isempty(where_list)
        cmd = "$cmd WHERE $(join(where_list, " AND "));"
    end
    sql_result = execute_or_die(cmd; verbose=verbose)

    # Collect the results from the SQL query, convert into arguments of the type
    # the constructor will expect, then construct objects from each row of r
    result = T[]
    for idx in 1:size(sql_result,1)
        args = Dict(f => fieldtype(T,f)(sql_result[idx,f]) for f in fields)
        push!(result, T(;args...))
    end

    for idx in 1:length(result)
        dbload_posthook!(result[idx]; verbose=verbose)
    end

    return result
end

function dbload_posthook!(dummy; verbose=false)
    # We do nothing in the normal case, override dbload_posthook for your own
    # types to do something interesting here.  Look at JLBuildcommand for an
    # example.
end
