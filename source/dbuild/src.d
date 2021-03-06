module dbuild.src;

import std.digest.md : MD5;

/// Source code interface
interface Source
{
    /// Feeds the digest in a way that makes a unique build identifier.
    void feedBuildId(ref MD5 digest);

    /// Obtain the source code.
    /// Implementation for local directories will simply return the local source dir,
    /// without consideration of the workDir.
    /// Implementation of source fetching (archive or scm) will download and
    /// extract (or clone) the source tree into workDir.
    /// Params:
    ///     workDir = work directory that should preferably be used to download
    ///               and extract the source code.
    /// Returns: the path to the src root directory.
    string obtain(in string workDir);

    /// Add patches to the source code.
    /// Patches are patch content, not patch filenames.
    /// Patches are applied with Git which must be found in PATH
    /// (even if source code is not a Git repo)
    final Source withPatch(in string[] patches)
    {
        return new PatchedSource(this, patches);
    }
}

/// Returns a Source pointing to a local existing directory
Source localSource(in string dir)
{
    return new LocalSource(dir);
}

/// Returns a Source pointing to a local directory within $DUB_PACKAGE
Source dubPkgSource(in string subdir)
{
    import std.path : buildPath;
    import std.process : environment;

    return new LocalSource(buildPath(environment["DUB_PACKAGE"], subdir));
}

/// Returns a Source that fetches and extract an archive into the work directory
/// md5 can be specified with an md5 checksum to check integrity of the downloaded
/// archive
Source archiveFetchSource(in string url, in string md5=null)
{
    import std.exception : enforce;

    enforce(isSupportedArchiveExt(url), url~" is not a supported archive type");
    return new ArchiveFetchSource(url, md5);
}

/// Returns a Source that will clone a git repo and checkout a specified commit.
/// commitRef can be a branch, tag, or commit hash. Anything `git checkout` will understand.
Source gitSource(in string url, in string commitRef)
{
    return new GitSource(url, commitRef);
}

private class LocalSource : Source
{
    string dir;
    this (in string dir)
    {
        import std.exception : enforce;
        import std.file : exists, isDir;

        enforce(exists(dir) && isDir(dir), dir~": no such directory!");
        this.dir = dir;
    }

    override void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        feedDigestData(digest, dir);
    }

    string obtain(in string)
    {
        return this.dir;
    }
}

private string srcLockPath(in string workDir)
{
    import std.path : buildPath;

    return buildPath(workDir, ".srcLock");
}

private string patchLockPath(in string workDir, in string patch)
{
    import dbuild.util : feedDigestData;
    import std.digest : toHexString, LetterCase;
    import std.digest.md : MD5;
    import std.path : buildPath;

    MD5 md5;
    feedDigestData(md5, patch);
    const binHash = md5.finish();
    const hash = toHexString!(LetterCase.lower)(binHash)[0 .. 7].idup;
    return buildPath(workDir, "."~hash~".patchLock");
}

private class ArchiveFetchSource : Source
{
    string url;
    string md5;
    this (in string url, in string md5)
    {
        this.url = url;
        this.md5 = md5;
    }

    override void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        feedDigestData(digest, url);
        feedDigestData(digest, md5);
    }

    override string obtain(in string workDir)
    {
        import dbuild.util : lockFile;
        import std.file : exists, isDir;
        import std.path : buildPath;
        import std.uri : decode;

        const decoded = decode(url);
        const fn = urlLastComp(decoded);
        const archive = buildPath(workDir, fn);

        const ldn = likelySrcDirName(archive);
        if (exists(ldn) && isDir(ldn)) {
            return ldn;
        }

        auto lock = lockFile(srcLockPath(workDir));
        downloadArchive(archive);
        return extractArchive(archive, workDir);
    }

    private void downloadArchive(in string archive)
    {
        import dbuild.util : checkMd5;
        import std.exception : enforce;
        import std.file : exists;
        import std.net.curl : download;
        import std.stdio : writefln;

        if (!exists(archive) || !(md5.length && checkMd5(archive, md5))) {
            if (exists(archive)) {
                import std.file : remove;
                remove(archive);
            }
            writefln("downloading %s", url);
            download(url, archive);

            enforce(!md5.length || checkMd5(archive, md5), "wrong md5 sum for "~archive);
        }
    }

    private string extractArchive(in string archive, in string workDir)
    {
        import std.file : remove;

        final switch(archiveFormat(archive)) {
        case ArchiveFormat.targz:
            const tarF = extractTarGz(archive);
            const res = extractTar(tarF, workDir);
            remove(tarF);
            return res;
        case ArchiveFormat.tar:
            return extractTar(archive, workDir);
        case ArchiveFormat.zip:
            return extractZip(archive, workDir);
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
        import std.stdio : File, writefln;
        import std.zlib : UnCompress;

        writefln("extracting %s", archive);

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

    private string extractTar(in string archive, in string workDir)
    {
        import dbuild.tar : extractTo, isSingleRootDir;
        import std.exception : enforce;
        import std.file : exists, isDir;
        import std.path : buildPath;
        import std.stdio : writefln;

        writefln("extracting %s", archive);

        string extractDir;
        string srcDir;
        string rootDir;
        if (isSingleRootDir(archive, rootDir)) {
            extractDir = workDir;
            srcDir = buildPath(workDir, rootDir);
        }
        else {
            extractDir = buildPath(workDir, "src");
            srcDir = extractDir;
        }

        // trusting src dir content?
        if (!exists(srcDir)) {
            extractTo(archive, extractDir);
        }

        enforce(isDir(srcDir));
        return srcDir;
    }

    private string extractZip(in string archive, in string workDir)
    {
        import std.digest.crc : crc32Of;
        import std.exception : enforce;
        import std.file : exists, isDir, mkdirRecurse, read, write;
        import std.path : buildNormalizedPath, buildPath, dirName, pathSplitter;
        import std.stdio : writeln, writefln;
        import std.zip : ZipArchive;

        writefln("extracting %s", archive);
        auto zip = new ZipArchive(read(archive));
        string extractDir;
        string srcDir;
        string rootDir;
        bool singleRoot = true;

        foreach(n, m; zip.directory) {
            const dir = pathSplitter(n).front;
            if (rootDir && dir != rootDir) {
                singleRoot = false;
                break;
            }
            if (!rootDir) rootDir = dir;
        }
        if (singleRoot) {
            extractDir = workDir;
            srcDir = buildPath(workDir, rootDir);
        }
        else {
            extractDir = buildPath(workDir, "src");
            srcDir = extractDir;
        }

        foreach(n, m; zip.directory) {
            const file = buildNormalizedPath(extractDir, n);
            if ((exists(file) && isDir(file)) || m.expandedSize == 0) continue;
            mkdirRecurse(dirName(file));
            zip.expand(m);
            enforce(m.expandedData.length == cast(size_t)m.expandedSize, "zip data does not have expected size");
            const crc32 = crc32Of(m.expandedData);
            const crc32_ = *(cast(const(uint)*)&crc32[0]);
            enforce(crc32_ == m.crc32, "CRC32 zip check failed");
            write(file, m.expandedData);
        }

        return srcDir;
    }
}

private class GitSource : Source
{
    string url;
    string commitRef;

    this (in string url, in string commitRef)
    {
        import dbuild.util : searchExecutable;
        import std.exception : enforce;

        enforce(searchExecutable("git"), "could not find git in PATH!");
        this.url = url;
        this.commitRef = commitRef;
    }

    override void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        feedDigestData(digest, url);
        feedDigestData(digest, commitRef);
    }
    override string obtain(in string workDir)
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

        const srcDir = buildPath(workDir, dirName);

        if (!exists(srcDir)) {
            runCommand(["git", "clone", url, dirName], workDir, false);
        }

        enforce(isDir(srcDir));

        runCommand(["git", "checkout", commitRef], srcDir, false);

        return srcDir;
    }
}

private class PatchedSource : Source
{
    const(string)[] patches;
    Source impl;

    this(Source impl, in string[] patches)
    {
        import dbuild.util : searchExecutable;
        import std.exception : enforce;

        enforce(searchExecutable("git"), "could not find git in PATH! Git is needed to apply patche");
        this.impl = impl;
        this.patches = patches;
    }

    void feedBuildId(ref MD5 digest)
    {
        import dbuild.util : feedDigestData;

        impl.feedBuildId(digest);
        feedDigestData(digest, patches);
    }

    string obtain(in string workDir)
    {
        import dbuild.util : lockFile;
        import std.process : Config, pipeProcess, Redirect, wait;
        import std.stdio : writefln;
        import std.file : exists;

        const dir = impl.obtain(workDir);

        writefln("Patching %s", dir);

        foreach (patch; patches) {
            const lockPath = patchLockPath(workDir, patch);
            if (exists(lockPath)) {
                continue;
            }
            const args = ["git", "apply", "-"];
            auto pipes = pipeProcess(args, Redirect.stderr|Redirect.stdin, null, Config.none, dir);
            pipes.stdin.write(patch);
            pipes.stdin.flush();
            pipes.stdin.close();
            wait(pipes.pid);
            auto lock = lockFile(lockPath);
        }

        return dir;
    }
}

private enum ArchiveFormat
{
    targz, tar, zip,
}

private immutable(string[]) supportedArchiveExts = [
    ".zip", ".tar.gz", ".tar"
];

private bool isSupportedArchiveExt(in string path)
{
    import std.algorithm : endsWith;
    import std.uni : toLower;

    const lpath = path.toLower;
    return lpath.endsWith(".zip") || lpath.endsWith(".tar.gz") || lpath.endsWith(".tar");
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

private string likelySrcDirName(in string archive)
{
    import std.algorithm : endsWith;
    import std.uni : toLower;

    assert(isSupportedArchiveExt(archive));

    foreach(ext; supportedArchiveExts) {
        if (archive.toLower.endsWith(ext)) {
            return archive[0 .. $-ext.length];
        }
    }
    assert(false);
}

unittest
{
    assert(likelySrcDirName("/path/archivename.tar.gz") == "/path/archivename");
}
