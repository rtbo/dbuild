module dbuild.buildsystem;

import dbuild.build;
import std.digest.md : MD5;

/// context of a build
struct BuildContext
{
    BuildDirs dirs;
    BuildType type;
    bool quiet;
}

/// simple interface to a build system (such as CMake, or Autotools)
interface BuildSystem
{
    /// Feeds the digest in a way that makes a unique build identifier.
    void feedBuildId(ref MD5 digest);
    /// Issue the commands to build the source code to the requested binaries.
    void issueCmds(BuildContext ctx);
}


/// Create a CMAKE build system, with generator and options.
/// env can be set to supply additional environment variables to cmake
/// execution context. (especially useful with MSVC)
/// Option should not deal with install dir or build type, which
/// are set from the build context.
/// The delegate will issue 3 commands: configure, build and install.
BuildSystem cmake(in string generator, in string[] options=null, string[string] env=null)
{
    import dbuild.util : searchExecutable;
    import std.exception : enforce;

    enforce(searchExecutable("cmake"), "Could not find CMake!");

    return new CMakeBuildSystem(generator, options, env);
}

private class CMakeBuildSystem : BuildSystem
{
    const(string) generator;
    const(string[]) options;
    string[string] env;

    this(in string generator, in string[] options, string[string] env)
    {
        this.generator = generator;
        this.options = options;
        this.env = env;
    }

    override void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        feedDigestData(digest, generator);
        feedDigestData(digest, options);
    }

    override void issueCmds(BuildContext ctx)
    {
        import dbuild.util : runCommands;

        const string buildType = ctx.type == BuildType.deb ? "Debug" : "Release";

        const string[] configCmd = [
            "cmake",
            "-G", generator, 
            "-DCMAKE_BUILD_TYPE="~buildType, 
            "-DCMAKE_INSTALL_PREFIX="~ctx.dirs.install
        ] ~ options ~ [
            ctx.dirs.src
        ];
        const string[] buildCmd = [
            "cmake", "--build", "."
        ];
        const string[] installCmd = [
            "cmake", "--build", ".", "--target", "install"
        ];

        runCommands(
            [ configCmd, buildCmd, installCmd ], ctx.dirs.build, ctx.quiet, env
        );
    }
}
