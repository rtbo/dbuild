module dbuild.build;

import dbuild.buildsystem : BuildSystem;
import dbuild.src : Source;
import dbuild.target : Target;


enum BuildType
{
    /// release build
    rel,
    /// debug build
    deb,
}

/// directories involved during a build
struct BuildDirs
{
    /// the source directory
    string srcDir;
    /// the build directory
    string buildDir;
    /// the install directory
    string installDir;

    /// build a path within the source directory
    /// Examples:
    /// -----------
    /// BuildDirs dirs;
    /// const mainFile = dirs.src("src", "main.c"); // get [src-dir]/src/main.c
    /// -----------
    string src(Comps...)(Comps comps) const
    {
        import std.path : buildPath;

        return buildPath(srcDir, comps);
    }

    /// build a path within the build directory
    string build(Comps...)(Comps comps) const
    {
        import std.path : buildPath;

        return buildPath(buildDir, comps);
    }

    /// build a path within the install directory
    string install(Comps...)(Comps comps) const
    {
        import std.path : buildPath;

        return buildPath(installDir, comps);
    }
}

struct BuildResult
{
    BuildDirs dirs;
    Target[string] targets;

    string artifact(in string name)
    {
        auto target = targets[name];
        if (!target.artifact) {
            target.resolveArtifact(dirs.installDir);
        }
        return target.artifact;
    }
}

struct Build
{
    /// Start to construct Build from within the .dub/subDir.
    /// This workDir will be where the source will be downloaded,
    /// extracted and where the build will take place.
    /// An exception will be thrown if dub environment cannot be detected.
    static Build dubWorkDir(string subDir="dbuild")
    {
        Build bld;
        bld._dubSubDir = subDir;
        return bld;
    }

    /// Start to construct Build from within the workDir.
    /// This workDir will be where the source will be downloaded,
    /// extracted and where the build will take place.
    static Build workDir(string workDir)
    {
        Build bld;
        bld._workDir = workDir;
        return bld;
    }

    /// Set the source package to be fetched
    Build src(Source source)
    {
        _source = source;
        return this;
    }

    Build debug_()
    {
        _type = BuildType.deb;
        return this;
    }

    Build release()
    {
        _type = BuildType.rel;
        return this;
    }

    Build type(in BuildType type)
    {
        _type = type;
        return this;
    }

    /// Set the install directory.
    /// If not called, it will be set automatically within the work dir
    Build install (string prefix)
    {
        _installPrefix = prefix;
        return this;
    }

    /// Do not log and shut down external commands output.
    Build quiet ()
    {
        _quiet = true;
        return this;
    }

    /// Add a target to be checked before attempting to start the build
    /// and to help resolving to a result artifact
    Build target(Target target)
    {
        _targets[target.name] = target;
        return this;
    }

    /// Perform the build
    /// Throws if build fails
    /// Returns: the directories involved in the build
    BuildResult build(BuildSystem buildSystem)
    {
        import dbuild.buildsystem : BuildContext;
        import dbuild.util : lockFile;
        import std.exception : enforce;
        import std.file : mkdirRecurse;
        import std.stdio : writeln;

        checkPrerequisites();
        ensureWorkDir();
        const srcDir = _source.obtain(_workDir);
        const buildId = computeBuildId(buildSystem);
        const buildDir = bldPath(buildId);
        mkdirRecurse(buildDir);
        if (!_installPrefix.length) {
            _installPrefix = installPath(buildId);
        }

        BuildDirs dirs;
        dirs.srcDir = srcDir;
        dirs.buildDir = buildDir;
        dirs.installDir = _installPrefix;

        if (!checkTargets(dirs)) {
            auto lock = lockFile(bldLockPath(buildId));
            buildSystem.issueCmds(BuildContext(dirs, _type, _quiet));
        }
        else {
            writeln("targets are up-to-date");
        }

        return BuildResult(dirs, _targets);
    }

    private string _dubSubDir;
    private string _workDir;
    private Source _source;
    private string _srcDir;
    private BuildType _type;
    private string _installPrefix;
    private bool _quiet;
    private Target[string] _targets;

    private void checkPrerequisites()
    {
        import dbuild.util : searchExecutable;
        import std.exception : enforce;

        enforce(_source, "did not set source");
    }

    private void ensureWorkDir()
    {
        import std.exception : enforce;
        import std.file : mkdirRecurse;
        import std.path : buildPath;
        import std.process : environment;

        if (!_workDir.length) {
            const dubPkgDir = environment.get("DUB_PACKAGE_DIR");
            enforce(dubPkgDir, "Dub environment could not be found. workDir must be used");

            enforce (_dubSubDir.length, "either workDir or dubWorkDir must be used");

            _workDir = buildPath(dubPkgDir, ".dub", _dubSubDir);
        }

        mkdirRecurse(_workDir);
    }

    private string bldLockPath(in string buildId)
    {
        import std.path : buildPath;

        return buildPath(_workDir, ".bldLock-"~buildId);
    }

    private string bldPath(in string buildId)
    {
        import std.path : buildPath;

        return buildPath(_workDir, "build-"~buildId);
    }

    private string installPath(in string buildId)
    {
        import std.path : buildPath;

        return buildPath(_workDir, "install-"~buildId);
    }

    private string computeBuildId(BuildSystem bs)
    {
        import dbuild.util : feedDigestData;
        import std.digest : toHexString, LetterCase;
        import std.digest.md : MD5;

        MD5 md5;
        _source.feedBuildId(md5);
        feedDigestData(md5, _type);
        feedDigestData(md5, _installPrefix);
        bs.feedBuildId(md5);

        const hash = md5.finish();
        return toHexString!(LetterCase.lower)(hash)[0 .. 7].idup;
    }

    private bool checkTargets(BuildDirs dirs)
    {
        if (!_targets.length) return false;
        foreach (t; _targets) {
            t.resolveArtifact(dirs.installDir);
            if (!t.check(dirs.srcDir)) return false;
        }
        return true;
    }
}
