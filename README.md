# jlbuild

> Your comments are my commits

GitHub comment-based interface to testing buildbots.  Simply ping `@jlbuild` in a comment, PR, issue, etc... and `@jlbuild` will do its best to build the relevant Julia version on all platforms, post download links and even execute small chunks of code across those plat
forms.

The syntax of a `@jlbuild` command is as follows:

    @jlbuild [hash] [!tag1] [!tag2]....
    ```
    [julia code]
    ```

All pieces within square brackets are optional.  If the comment being made is within a pull request, is a comment upon a specific commit, or in some other fashion is obviously related to a single Julia revision, `@jlbuild` should automatically figure out which commit you're discussing and build the appropriate version.  However, you can always specify the version manually, e.g. `@jlbuild 1a2b3c4d`.

Tags are used to alter the default behavior of `jlbuild` somewhat.  As of this writing, two tags are available:

* `!nuke` instructs the buildbots to completely clean out the buildbots before building this version of Julia, a very important feature when dealing with buildsystem changes.  Example: `@jlbuild 1a2b3c4d !nuke`.

* `!filter=x,y,z` filters the buildbots that will be scheduled.  Filters are comma-separated strings, where any builder that contains any of the filtering criterion will be included. Example: `@jlbuild !nuke !filter=linux64,win,ppc`.

* `!flags=x,y,z` will add extra flags to the `make` invocation that builds julia.  Example: `@jlbuild !filter=arm !flags=BUILD_CUSTOM_LIBCXX=1,BUILD_LLVM_CLANG=1`.

Finally, Julia code can be included to be run using the newly-built version of Julia.  Binary artifacts from the build will also be posted for easy access.
