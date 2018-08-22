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

        auto lock = lockFile(srcLockPath(workDir));
        const archive = downloadArchive(workDir);
        return extractArchive(archive, workDir);
    }

    private string downloadArchive(in string workDir)
    {
        import dbuild.util : checkMd5;
        import std.exception : enforce;
        import std.file : exists;
        import std.net.curl : download;
        import std.path : buildPath;
        import std.uri : decode;
        import std.stdio : writefln;

        const decoded = decode(url);
        const fn = urlLastComp(decoded);
        const archive = buildPath(workDir, fn);

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

    private string extractZip(in string archive, in string)
    {
        import std.stdio : writefln;

        writefln("extracting %s", archive);
        assert(false, "unimplemented");
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