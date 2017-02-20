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
    global logfile
    const CSI = Terminals.CSI
    const date_color = Base.text_colors[:cyan]
    const normal_color = Base.text_colors[:normal]
    datestr = Dates.format(now(), "[dd u yyyy HH:MM:SS.sss]: ")

    # Only write the clear line/color stuff out to STDOUT
    write(STDOUT, "\r$(CSI)0K$(date_color)")
    logwrite(datestr)
    write(STDOUT, normal_color)

    splitlines = split(msg, "\n")
    logwrite(splitlines[1] * "\n")
    for line in splitlines[2:end]
        logwrite(" "^(strwidth(datestr)-2) * "> " * line * "\n")
    end

    flush(STDOUT)
    flush(logfile)
end
