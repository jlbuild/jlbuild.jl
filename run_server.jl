include("src/jlbuild.jl")
using jlbuild

run_server()
wait(jlbuild.event_loop_task)
