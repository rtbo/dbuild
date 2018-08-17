module dbuild.build;

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

    Build cmake(string[] options=null)
    {
        _bsType = BuildSystemType.cmake;
        _bsOptions = options;
        _install = true;
        return this;
    }

    Build autotools(string[] options=null)
    {
        _bsType = BuildSystemType.autotools;
        _bsOptions = options;
        return this;
    }

    Build release()
    {
        _type = Type.rel;
        return this;
    }

    Build debug_()
    {
        _type = Type.deb;
        return this;
    }

    Build install (string prefix=null)
    {
        _install = true;
        _installPrefix = prefix;
        return this;
    }

    Build quiet ()
    {
        _quiet = true;
        return this;
    }

    /// Perform the build
    BuildResult build()
    {
        import dbuild.util : lockFile;

        BuildResult res;

        ensureWorkDir();
        ensureSrcDir();

        const buildId = computeBuildId();
        auto lock = lockFile(bldLockPath(buildId));
        const buildDir = bldPath(buildId);


        return res;
    }

    private enum Type
    {
        rel, deb,
    }

    private string _dubSubDir;
    private string _workDir;
    private SrcFetch _srcFetch;
    private string _srcDir;
    private BuildSystemType _bsType;
    private string[] _bsOptions;
    private Type _type;
    private bool _install;
    private string _installPrefix;
    private bool _quiet;

    private void ensureWorkDir()
    {
        import std.array : array;
        import std.exception : enforce;
        import std.file : mkdirRecurse;
        import std.path : chainPath;
        import std.process : environment;

        if (!_workDir.length) {
            const dubPkgDir = environment.get("DUB_PACKAGE_DIR");
            enforce(dubPkgDir, "Dub environment could not be found. workDir must be used");

            enforce (_dubSubDir.length, "either workDir or dubWorkDir must be used");

            _workDir = chainPath(dubPkgDir, ".dub", _dubSubDir).array;
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

            const isGit = url.endsWith(".git") || url.startsWith("git://");

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

    @property string srcLockPath()
    {
        import dbuild.util : makePath;

        return makePath(_workDir, ".srcLock");
    }

    @property string bldLockPath(in string buildId)
    {
        import dbuild.util : makePath;

        return makePath(_workDir, ".bldLock-"~buildId);
    }

    @property string bldPath(in string buildId)
    {
        import dbuild.util : makePath;

        return makePath(_workDir, "build-"~buildId);
    }

    private string ensureArchive(in string url)
    {
        import std.array : array;
        import std.exception : assumeUnique, enforce;
        import std.file : exists;
        import std.net.curl : download;
        import std.path : chainPath;
        import std.uri : decode;
        import std.stdio : writefln;

        const decoded = decode(url);
        const fn = urlLastComp(decoded);
        const archive = assumeUnique(chainPath(_workDir, fn).array);

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
        import std.array : array;
        import std.exception : assumeUnique, enforce;
        import std.file : exists, isDir;
        import std.path : chainPath;

        string extractDir;
        string srcDir;
        string rootDir;
        if (isSingleRootDir(archive, rootDir)) {
            extractDir = _workDir;
            srcDir = assumeUnique(chainPath(_workDir, rootDir).array);
        }
        else {
            extractDir = assumeUnique(chainPath(_workDir, "src").array);
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
        import std.array : array;
        import std.exception : assumeUnique, enforce;
        import std.file : exists, isDir;
        import std.path : chainPath;
        import std.process : pipeProcess, Redirect;
        import std.uri : decode;

        enforce(commitRef.length, "must specify commitRef for git checkout");

        const decoded = decode(url);
        auto dirName = urlLastComp(decoded);
        if (dirName.endsWith(".git")) {
            dirName = dirName[0 .. $-4];
        }

        const srcDir = assumeUnique(chainPath(_workDir, dirName).array);

        if (!exists(srcDir)) {
            runCommand("git clone "~url~" "~dirName, _workDir, _quiet);
        }

        enforce(isDir(srcDir));

        runCommand("git checkout "~commitRef, srcDir, _quiet);

        return srcDir;
    }

    string computeBuildId() 
    {
        import dbuild.util : feedDigestData;
        import std.digest : toHexString, LetterCase;
        import std.digest.md : MD5;

        MD5 md5;
        feedDigestData(md5, _srcFetch._url);
        feedDigestData(md5, _srcFetch._commitRef);
        feedDigestData(md5, _type);
        feedDigestData(md5, _bsType);
        feedDigestData(md5, _bsOptions);
        feedDigestData(md5, cast(ubyte)_install);
        feedDigestData(md5, _installPrefix);

        const hash = md5.finish();
        return toHexString!(LetterCase.lower)(hash).idup;
    }
}

struct BuildResult
{
    bool success;
    string buildDir;
    string installDir;
}

private enum BuildSystemType
{
    unset, cmake, autotools
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
in(md5.length)
{
    import std.digest : LetterCase, toHexString;
    import std.digest.md : md5Of;
    import std.uni : toLower;
    import std.stdio : File;

    ubyte[1024] buf = void;
    auto f = File(path, "rb");
    return md5Of(f.byChunk(buf[])).toHexString!(LetterCase.lower)() == md5.toLower();
}

// private struct Builder
// {
//     private enum Type { rel, deb }
//     private Type _type;
//     private BuildSystem _buildSystem;
//     private SrcFetch _srcFetch;
//     private Toolchain _toolchain;
//     private string _dirFmt;

//     private string computeBuildId() 
//     {
//         import dbuild.util : addHash;
//         import std.digest : toHexString;
//         import std.digest.md : MD5;
//         import std.format : format;

//         MD5 md5;

//         addHash(md5, _type);
//         _buildSystem.feedHash(md5);
//         _srcFetch.feedHash(md5);
//         _toolchain.feedHash(md5);
        
//         const hash = md5.finish();
//         return format(_dirFmt, toHexString(hash[]));
//     }

// }
