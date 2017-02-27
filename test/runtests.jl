using Base.Test
include("../src/jlbuild.jl")
using jlbuild

# First, test that we are able to probe gitshas properly
test_gitsha = "a9cbc036ac62dc5ba5200416ca7b40a2f9aa59ea"
short_gitsha = test_gitsha[1:10]
@testset "gitsha verify" begin
    # Ensure a full gitsha works
    @test verify_gitsha(test_gitsha; auto_update=false)

    # Ensure a truncated (but still unique) gitsha works
    @test verify_gitsha(short_gitsha; auto_update=false)

    # Ensure branch names do not work
    @test !verify_gitsha("master"; auto_update=false)

    # Ensure truncated (and non-unique) gitshas do not work
    @test !verify_gitsha(test_gitsha[1:3]; auto_update=false)

    # Ensure random gibberish does not work
    @test !verify_gitsha("this is not a gitsha"; auto_update=false)
end

@testset "gitsha normalize" begin
    @test normalize_gitsha(test_gitsha) == test_gitsha
    @test normalize_gitsha(short_gitsha) == test_gitsha
    @test_throws LibGit2.Error.GitError normalize_gitsha(test_gitsha[1:3])
end

test_code = strip("""
println("Hello, world!")
""")
@testset "JLBuildCommand" begin
    # Test that the constructors and whatnot work like we expect
    jlbc = JLBuildCommand(test_gitsha, test_code)
    @test jlbc.gitsha == test_gitsha
    @test jlbc.code == test_code
    @test !jlbc.should_nuke
    @test !jlbc.submitted
    @test isempty(jlbc.builder_filter)
end


# A giant "comment" that has some `@jlbuild` commands embedded within it
long_gitsha_test = """
this is a test. somewhere in here I will say a fake trigger, like
@jlbuild 1a2b3c4d
and then I will say another one:
@jlbuild `6a7b8c9d`
and then I will have a real one, both quoted and unquoted and short
@jlbuild $test_gitsha
@jlbuild `$short_gitsha`
And a real one that is split
@jlbuild
78f3c82f92a3259f2372543ab8a7c4252fa2999f
"""
long_gitshas = ["1a2b3c4d", "6a7b8c9d", test_gitsha, short_gitsha]

# Test stuff for commands
cmd_test_code = strip("""
for idx = 1:10
    println("Hello, I am: \$(Base.GIT_VERSION_INFO.commit)")
end
""")
cmd_test = """
Ensure that this first code block doesn't get matched with the second
@jlbuild $test_gitsha
```
```

@jlbuild $test_gitsha
```julia
$cmd_test_code
```
"""
@testset "command parsing" begin
    # Test these generate no commands
    @test isempty(parse_commands(""))
    @test isempty(parse_commands("@jlbuild"))

    # Test simple one-off parsings, both within and without backticks
    @test parse_commands("@jlbuild $test_gitsha")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild \t $test_gitsha\n")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild `$test_gitsha`")[1].gitsha == test_gitsha

    # Test multiline parsing works, but not with something else preceeding the
    # command on the same line.
    @test parse_commands("a\n@jlbuild $test_gitsha\na")[1].gitsha == test_gitsha
    @test isempty(parse_commands("\nlololol\nkekeke @jlbuild $test_gitsha"))

    # Test nuke tag works
    @test parse_commands("@jlbuild $test_gitsha !nuke")[1].should_nuke

    # Test filter tag works
    cmd = parse_commands("@jlbuild $test_gitsha !filter=osx,win")[1]
    @test cmd.builder_filter == "osx,win"

    # Test builder_filter works with the filter we just gave it
    builders = ["package_osx64", "package_linux64", "package_win32"]
    @test builder_filter(cmd, builders) == ["package_osx64", "package_win32"]

    # Test two tags together works
    cmd = parse_commands("@jlbuild $test_gitsha !nuke !filter=linux")[1]
    @test cmd.should_nuke
    @test cmd.builder_filter == "linux"
    @test builder_filter(cmd, builders) == ["package_linux64"]

    # Test parsing of a large comment
    @test [c.gitsha for c in parse_commands(long_gitsha_test)] == long_gitshas

    # Test parsing of multiple code blocks
    @test parse_commands(cmd_test) == [
        JLBuildCommand(test_gitsha, ""),
        JLBuildCommand(test_gitsha, cmd_test_code)
    ]
end
