module dbuild.build;

import dbuild.buildsystem : BuildSystem;
import dbuild.target : Target;

struct SrcFetch
{
    static SrcFetch fromUrl(string url)
    {
        SrcFetch src;
        src._url = url;
        return src;
    }

    SrcFetch commitRef(string commitRef)
    {
        _commitRef = commitRef;
        return this;
    }

    SrcFetch md5(string md5)
    {
        _md5 = md5;
        return this;
    }

    private string _url;
    private string _commitRef;
    private string _md5;
}

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
    Build src(SrcFetch srcFetch)
    {
        _srcFetch = srcFetch;
        return this;
    }

    /// Set the source package to a local directory
    Build src(string localDir)
    {
        _srcDir = localDir;
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
        _targets[target.target] = target;
        return this;
    }

    /// Perform the build
    /// Throws if build fails
    /// Returns: the directories involved in the build
    BuildDirs build(BuildSystem buildSystem)
    {
        import dbuild.buildsystem : BuildContext;
        import dbuild.util : lockFile;
        import std.exception : enforce;
        import std.file : mkdirRecurse;

        checkPrerequisites();
        ensureWorkDir();
        ensureSrcDir();

        const buildId = computeBuildId(buildSystem);
        const buildDir = bldPath(buildId);
        mkdirRecurse(buildDir);
        if (!_installPrefix.length) {
            _installPrefix = installPath(buildId);
        }

        BuildDirs dirs;
        dirs.srcDir = _srcDir;
        dirs.buildDir = buildDir;
        dirs.installDir = _installPrefix;

        if (!checkTargets(dirs)) {
            auto lock = lockFile(bldLockPath(buildId));
            buildSystem.issueCmds(BuildContext(dirs, _type, _quiet));
        }

        return BuildResult(dirs, _targets);
    }

    private string _dubSubDir;
    private string _workDir;
    private SrcFetch _srcFetch;
    private string _srcDir;
    private BuildType _type;
    private string _installPrefix;
    private bool _quiet;
    private Target[string] _targets;

    private void checkPrerequisites()
    {
        import dbuild.util : searchExecutable;
        import std.exception : enforce;

        enforce(_srcDir.length || !isGitUrl(_srcFetch._url) || searchExecutable("git"),
                "could not find git!");
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

    private void ensureSrcDir()
    {
        import dbuild.util : lockFile;
        import std.algorithm : startsWith, endsWith;
        import std.exception : enforce;

        if (!_srcDir) {

            auto lock = lockFile(srcLockPath);

            const url = _srcFetch._url;

            const isArchiveDownload = isSupportedArchiveExt(url) && (
                url.startsWith("https://") || url.startsWith("http://") || url.startsWith("ftp://")
            );

            const isGit = isGitUrl(url);

            enforce(isArchiveDownload || isGit, "only zip, tar, tar.gz archives or git repo " ~
                                                "are supported for source fetch");

            if (isArchiveDownload) {
                const archive = ensureArchive(url);
                _srcDir = extractArchive(archive);
            }
            else if (isGit) {
                _srcDir = ensureGit(url, _srcFetch._commitRef);
            }
            else {
                assert(false, "unsupported src url: "~url);
            }
        }
    }

    private @property string srcLockPath()
    {
        import std.path : buildPath;

        return buildPath(_workDir, ".srcLock");
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

    private bool isGitUrl(in string url)
    {
        import std.algorithm : startsWith, endsWith;

        return url.endsWith(".git") || url.startsWith("git://");
    }

    private string ensureArchive(in string url)
    {
        import std.exception : enforce;
        import std.file : exists;
        import std.net.curl : download;
        import std.path : buildPath;
        import std.uri : decode;
        import std.stdio : writefln;

        const decoded = decode(url);
        const fn = urlLastComp(decoded);
        const archive = buildPath(_workDir, fn);

        const md5 = _srcFetch._md5;

        if (!exists(archive) || !(md5.length && checkMd5(archive, md5))) {
            if (exists(archive)) {
                import std.file : remove;
                remove(archive);
            }
            writefln("downloading %s", url);
            download(url, archive);

            enforce(!md5.length || checkMd5(archive, md5), "wrong md5 sum for "~archive);
        }

        return archive;
    }

    private string extractArchive(const string archive)
    {
        import std.file : remove;

        final switch(archiveFormat(archive)) {
        case ArchiveFormat.targz:
            const tarF = extractTarGz(archive);
            const res = extractTar(tarF);
            remove(tarF);
            return res;
        case ArchiveFormat.tar:
            return extractTar(archive);
        case ArchiveFormat.zip:
            return extractZip(archive);
        }
    }

    /// extract .tar.gz to .tar, returns the .tar file path
    private string extractTarGz(const string archive)
    in { assert(archive[$-7 .. $] == ".tar.gz"); }
    out(res) { assert(res[$-4 .. $] == ".tar"); }
    body {
        import std.algorithm : map;
        import std.exception : enforce;
        import std.file : exists, remove;
        import std.stdio : File;
        import std.zlib : UnCompress;

        const tarFn = archive[0 .. $-3];
        enforce(!exists(tarFn), tarFn~" already exists");

        auto inF = File(archive, "rb");
        auto outF = File(tarFn, "wb");

        UnCompress decmp = new UnCompress;
        foreach (chunk; inF.byChunk(4096).map!(x => decmp.uncompress(x)))
        {
            outF.rawWrite(chunk);
        }

        return tarFn;
    }

    private string extractTar(in string archive)
    {
        import dbuild.tar : extractTo, isSingleRootDir;
        import std.exception : enforce;
        import std.file : exists, isDir;
        import std.path : buildPath;

        string extractDir;
        string srcDir;
        string rootDir;
        if (isSingleRootDir(archive, rootDir)) {
            extractDir = _workDir;
            srcDir = buildPath(_workDir, rootDir);
        }
        else {
            extractDir = buildPath(_workDir, "src");
            srcDir = extractDir;
        }

        // trusting src dir content?
        if (!exists(srcDir)) {
            extractTo(archive, extractDir);
        }

        enforce(isDir(srcDir));
        return srcDir;
    }

    private string extractZip(in string archive)
    {
        assert(false, "unimplemented");
    }

    private string ensureGit(string url, string commitRef)
    {
        import dbuild.util : runCommand;
        import std.algorithm : endsWith;
        import std.exception : enforce;
        import std.file : exists, isDir;
        import std.path : buildPath;
        import std.process : pipeProcess, Redirect;
        import std.uri : decode;

        enforce(commitRef.length, "must specify commitRef for git checkout");

        const decoded = decode(url);
        auto dirName = urlLastComp(decoded);
        if (dirName.endsWith(".git")) {
            dirName = dirName[0 .. $-4];
        }

        const srcDir = buildPath(_workDir, dirName);

        if (!exists(srcDir)) {
            runCommand(["git", "clone", url, dirName], _workDir, _quiet);
        }

        enforce(isDir(srcDir));

        runCommand(["git", "checkout", commitRef], srcDir, _quiet);

        return srcDir;
    }

    string computeBuildId(BuildSystem bs)
    {
        import dbuild.util : feedDigestData;
        import std.digest : toHexString, LetterCase;
        import std.digest.md : MD5;

        MD5 md5;
        feedDigestData(md5, _srcFetch._url);
        feedDigestData(md5, _srcFetch._commitRef);
        feedDigestData(md5, _type);
        feedDigestData(md5, _installPrefix);
        bs.feedBuildId(md5);

        const hash = md5.finish();
        return toHexString!(LetterCase.lower)(hash)[0 .. 7].idup;
    }

    private bool checkTargets(BuildDirs dirs)
    {
        foreach (t; _targets) {
            t.resolveTargetPath(dirs.installDir);
            if (!t.check(dirs.srcDir)) return false;
        }
        return true;
    }
}

private enum ArchiveFormat
{
    targz, tar, zip,
}

private bool isSupportedArchiveExt(in string path)
{
    import std.algorithm : endsWith;

    return path.endsWith(".zip") || path.endsWith(".tar.gz") || path.endsWith(".tar");
}

private ArchiveFormat archiveFormat(in string path)
{
    import std.algorithm : endsWith;

    if (path.endsWith(".zip")) return ArchiveFormat.zip;
    if (path.endsWith(".tar.gz")) return ArchiveFormat.targz;
    if (path.endsWith(".tar")) return ArchiveFormat.tar;
    assert(false);
}

private string urlLastComp(in string url)
{
    size_t ind = url.length - 1;
    while (ind >= 0 && url[ind] != '/') {
        ind--;
    }
    return url[ind+1 .. $];
}

private bool checkMd5(in string path, in string md5)
in { assert(md5.length); }
body {
    import std.digest : LetterCase, toHexString;
    import std.digest.md : md5Of;
    import std.uni : toLower;
    import std.stdio : File;

    ubyte[1024] buf = void;
    auto f = File(path, "rb");
    return md5Of(f.byChunk(buf[])).toHexString!(LetterCase.lower)() == md5.toLower();
}
