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

/// Helper to create a CMAKE build system, with generator and options.
/// Option should not deal with install dir or build type, which
/// are set from the build context.
/// The build system will issue 3 commands: configure, build and install.
struct CMake
{
    static CMake create(string generator=null, string[] options=null)
    {
        import dbuild.util : searchExecutable;
        import std.exception : enforce;

        enforce(searchExecutable("cmake"), "Could not find CMake!");
        CMake cmake;
        cmake._gen = generator;
        cmake._options = options;
        return cmake;
    }

    version(Windows)
    CMake withMsvcSetup(int minVer=0, string[] vcvarsOptions=null)
    {
        import std.exception : enforce;

        enforce(tryMsvcSetup(minVer, vcvarsOptions), "Could not find suitable MSVC install");
        return this;
    }

    version(Windows)
    bool tryMsvcSetup(int minVer=0, string[] vcvarsOptions=null)
    {
        import dbuild.msvc : detectMsvcInstalls, msvcEnvironment;
        import dbuild.util : searchExecutable;

        if (searchExecutable("cl")) return true; // TODO: what version

        auto installs = detectMsvcInstalls();
        if (!installs.length || installs[0].ver[0] < minVer) {
            return false;
        }
        _env = msvcEnvironment(installs[0].vcvarsBat, vcvarsOptions);
        _additionalHashFeed = installs[0].vcvarsBat ~ vcvarsOptions;
        return true;
    }

    private string findDefaultGenerator()
    {
        import dbuild.util : searchExecutable;

        version(Windows)
        {
            import dbuild.msvc : dubArchOptions;

            if (tryMsvcSetup(0, dubArchOptions())) {
                return "NMake Makefiles";
            }
        }
        if (searchExecutable("ninja")) {
            if (searchExecutable("gcc") || searchExecutable("clang")) {
                return "Ninja";
            }
        }
        version(Windows) {
            if (searchExecutable("mingw32-make")) {
                return "MinGW Makefiles";
            }
            else if (searchExecutable("make")) { // under cygwin?
                return "MSYS Makefiles";
            }
        }
        else {
            if (searchExecutable("make")) {
                return "Unix Makefiles";
            }
        }
        return null;
    }

    /// get the result BuildSystem
    BuildSystem get()
    {
        import std.exception : enforce;

        if (!_gen) {
            _gen = enforce(findDefaultGenerator(), "Could not find suitable CMake generator");
        }

        return new CMakeBuildSystem(_gen, _options, _env, _additionalHashFeed);
    }

    private string _gen;
    private string[] _options;
    private string[string] _env;
    private string[] _additionalHashFeed;
}


private class CMakeBuildSystem : BuildSystem
{
    const(string) generator;
    const(string[]) options;
    string[string] env;
    const(string[]) additionalHashFeed;

    this(in string generator, in string[] options, string[string] env, string[] additionalHashFeed)
    {
        this.generator = generator;
        this.options = options;
        this.env = env;
        this.additionalHashFeed = additionalHashFeed;
    }

    override void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        feedDigestData(digest, generator);
        feedDigestData(digest, options);
        if (additionalHashFeed.length) feedDigestData(digest, additionalHashFeed);
    }

    override void issueCmds(BuildContext ctx)
    {
        import dbuild.util : runCommands;

        const string buildType = ctx.type == BuildType.deb ? "Debug" : "Release";

        const string[] configCmd = [
            "cmake",
            "-G", generator,
            "-DCMAKE_BUILD_TYPE="~buildType,
            "-DCMAKE_INSTALL_PREFIX="~ctx.dirs.installDir
        ] ~ options ~ [
            ctx.dirs.srcDir
        ];
        const string[] buildCmd = [
            "cmake", "--build", "."
        ];
        const string[] installCmd = [
            "cmake", "--build", ".", "--target", "install"
        ];

        runCommands(
            [ configCmd, buildCmd, installCmd ], ctx.dirs.buildDir, ctx.quiet, env
        );
    }
}
