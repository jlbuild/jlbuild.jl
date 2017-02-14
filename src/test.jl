using Base.Test
include("jlbuild.jl")

# First, test that we are able to probe gitshas properly
test_gitsha = "a9cbc036ac62dc5ba5200416ca7b40a2f9aa59ea"
@testset "LibGit2 usage" begin
    @test verify_gitsha(test_gitsha)
    @test verify_gitsha(test_gitsha[1:10])
    @test !verify_gitsha(test_gitsha[1:3]; auto_update=false)
    @test !verify_gitsha("this is not a gitsha"; auto_update=false)
end

long_gitsha_test = """
this is a test. somewhere in here I will say a fake trigger, like
@jlbuild 1a2b3c4d
and then I will say another one:
@jlbuild `6a7b8c9d`
and then I will have a real one, both quoted and unquoted and short
@jlbuild $test_gitsha
@jlbuild `$(test_gitsha[1:10])`
And a real one that is split
@jlbuild
78f3c82f92a3259f2372543ab8a7c4252fa2999f
"""
long_gitshas = ["1a2b3c4d", "6a7b8c9d", test_gitsha, test_gitsha[1:10]]

# Test stuff for commands
cmd_test_code = strip("""
for idx = 1:10
    println("Hello, I am: \$(Base.GIT_VERSION_INFO.commit)")
end
""")
cmd_test = """
Ensure that this first code block doesn't get matched with the second
@jlbuild 12345678
```
```

@jlbuild 1a2b3c4d
```julia
$cmd_test_code
```
"""
@testset "command parsing" begin
    # Next, test parsing out of gitsha's
    @test isempty(parse_commands(""))
    @test isempty(parse_commands("@jlbuild"))
    @test isempty(parse_commands(""))
    @test parse_commands("@jlbuild $test_gitsha")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild $test_gitsha\n")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild `$test_gitsha`")[1].gitsha == test_gitsha
    @test parse_commands("a\n@jlbuild $test_gitsha\na")[1].gitsha == test_gitsha
    @test isempty(parse_commands("\nlololol\nkekeke @jlbuild $test_gitsha"))
    @test [c.gitsha for c in parse_commands(long_gitsha_test)] == long_gitshas
    @test parse_commands(cmd_test) == [
        JLBuildCommand("12345678"),
        JLBuildCommand("1a2b3c4d", cmd_test_code)
    ]
end
