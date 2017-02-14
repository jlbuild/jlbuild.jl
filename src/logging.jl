using Base.Terminals
import Base: log

if !isdefined(:logfile)
    const logfile = open("/tmp/jlbuild.log", "a")
    write(logfile, Dates.format(now(), "[dd u yyyy HH:MM:SS.sss]: "))
    write(logfile, "$(basename(PROGRAM_FILE)) $(join(ARGS, " "))\n")
end

function logwrite(text::AbstractString)
    global logfile
    write(logfile, text)
    write(STDOUT, text)
end

function log(x)
    return log(string(x))
end

function log(msg::AbstractString)
    # If a multiline message is sent in for logging, log each line one at a time
    msg_lines = filter(x -> !isempty(x), split(msg, "\n"))
    if length(msg_lines) > 1
        for line in msg_lines
            log(line)
        end
        return
    end
    global logfile
    const CSI = Terminals.CSI
    datestr = Dates.format(now(), "[dd u yyyy HH:MM:SS.sss]: ")
    logwrite("\r$(CSI)0K")
    logwrite(datestr)

    splitlines = split(msg, "\n")
    logwrite(splitlines[1])
    logwrite("\n")
    for line in splitlines[2:end]
        logwrite(" "^strwidth(datestr))
        logwrite(line)
        logwrite("\n")
    end
    flush(STDOUT)
    flush(logfile)
end
