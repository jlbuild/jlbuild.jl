using Base.Test
include("../src/jlbuild.jl")
using jlbuild

# Mockup some internal datastructures with testing data
suffixes = ["linux64", "osx64", "win32", "linuxarmv7l"]
for idx in 1:length(suffixes)
    jlbuild.build_builder_ids[idx] = "package_$(suffixes[idx])"
    jlbuild.code_builder_ids[idx]  = "code_run_$(suffixes[idx])"
    jlbuild.nuke_builder_ids[idx]  = "nuke_$(suffixes[idx])"
end

# First, test that we are able to probe gitshas properly
test_gitsha    = "a9cbc036ac62dc5ba5200416ca7b40a2f9aa59ea"
v060rc2_gitsha = "68e911be534f84f6201cbdd5d92ef0757af1238a"
short_gitsha = test_gitsha[1:10]
@testset "gitsha verify" begin
    # Ensure a full gitsha works
    @test verify_gitsha(test_gitsha; auto_update=false)

    # Ensure a truncated (but still unique) gitsha works
    @test verify_gitsha(short_gitsha; auto_update=false)

    # Ensure branch names do not work
    @test !verify_gitsha("master"; auto_update=false)

    # Ensure tag names do work
    @test verify_gitsha("v0.6.0-rc2"; auto_update=false)

    # Ensure truncated (and non-unique) gitshas do not work
    @test !verify_gitsha(test_gitsha[1:3]; auto_update=false)

    # Ensure random gibberish does not work
    @test !verify_gitsha("this is not a gitsha"; auto_update=false)
end

@testset "gitsha normalize" begin
    @test normalize_gitsha(test_gitsha) == test_gitsha
    @test normalize_gitsha(short_gitsha) == test_gitsha
    @test normalize_gitsha("v0.6.0-rc2") == v060rc2_gitsha
    @test_throws LibGit2.Error.GitError normalize_gitsha(test_gitsha[1:3])
end

test_code = strip("""
println("Hello, world!")
""")
@testset "JLBuildCommand" begin
    # Test that the constructors and whatnot work like we expect
    jlbc = JLBuildCommand(gitsha=test_gitsha, code=test_code)
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
@jlbuild `v0.6.0-rc2`
And a real one that is split
@jlbuild
78f3c82f92a3259f2372543ab8a7c4252fa2999f
"""
long_gitshas = [
    "1a2b3c4d",
    "6a7b8c9d",
    test_gitsha,
    short_gitsha,
    "v0.6.0-rc2",
]

# Test stuff for commands
cmd_code = strip("""
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
$cmd_code
```

Test that code + tags works properly
@jlbuild $test_gitsha !nuke
```julia
$cmd_code
```
"""
@testset "command parsing" begin
    # Test these generate no commands
    @test isempty(parse_commands(""))
    @test isempty(parse_commands("@jlbuild"))

    # Test simple one-off parsings, both with and without backticks
    @test parse_commands("@jlbuild $test_gitsha")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild \t $test_gitsha\n")[1].gitsha == test_gitsha
    @test parse_commands("@jlbuild `$test_gitsha`")[1].gitsha == test_gitsha
    v060rc2 = parse_commands("@jlbuild `v0.6.0-rc2`")[1]
    @test v060rc2.gitsha == "v0.6.0-rc2"
    @test normalize_gitsha(v060rc2.gitsha) == v060rc2_gitsha

    # Test multiline parsing works, but not with something else preceeding the
    # command on the same line.
    @test parse_commands("a\n@jlbuild $test_gitsha\na")[1].gitsha == test_gitsha
    @test isempty(parse_commands("\nlololol\nkekeke @jlbuild $test_gitsha"))

    # Test nuke tag works properly
    @test parse_commands("@jlbuild $test_gitsha !nuke")[1].should_nuke
    @test isempty(parse_commands("@jlbuild !nuke $test_gitsha"))

    # Test flags tag works properly
    flags = "DEPS_GIT=1,OPENBLAS_BRANCH=develop,OPENBLAS_SHA1=4227049c7d"
    cmd = parse_commands("@jlbuild $test_gitsha !flags=$flags")[1]
    @test cmd.extra_make_flags == flags
    @test extra_make_flags(cmd) == [
        "DEPS_GIT=1",
        "OPENBLAS_BRANCH=develop",
        "OPENBLAS_SHA1=4227049c7d",
    ]

    # Test rebuild tag works properly
    @test parse_commands("@jlbuild $test_gitsha !rebuild")[1].force_rebuild

    # Test filter tag works
    cmd = parse_commands("@jlbuild $test_gitsha !filter=osx,win")[1]
    @test cmd.builder_filter == "osx,win"
    @test builder_suffixes(cmd) == ["osx64", "win32"]

    # Test two tags together works
    cmd = parse_commands("@jlbuild $test_gitsha !nuke !filter=linux64")[1]
    @test cmd.should_nuke
    @test cmd.builder_filter == "linux64"

    # Test parsing of a large comment
    @test [c.gitsha for c in parse_commands(long_gitsha_test)] == long_gitshas

    # Test parsing of multiple code blocks
    cmd_results = parse_commands(cmd_test)
    @test length(cmd_results) == 3
    @test all(r.gitsha == test_gitsha for r in cmd_results)
    @test cmd_results[1].code == ""
    @test all(r.code == cmd_code for r in cmd_results[2:end])
    @test all(r.should_nuke == false for r in cmd_results[1:2])
    @test cmd_results[3].should_nuke == true
end
