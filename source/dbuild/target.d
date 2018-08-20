module dbuild.target;


/// A target to be checked for, to possibly bypass the build
abstract class Target
{
    /// target artifact
    string target;
    /// files used to build the artifacts in the src dir
    string[] srcFiles;
    /// full path to the target artifact
    string targetPath;

    private this(string target, string[] srcFiles)
    {
        this.target = target;
        this.srcFiles = srcFiles;
    }

    /// resolve the target file in the install dir, and set the targetPath field
    abstract void resolveTargetPath(in string installDir);

    /// Check if the target is up-to-date vs the provided src files.
    /// Returns: true if the target is up-to-date, false if it needs rebuild
    bool check(in string srcDir)
    {
        import std.algorithm : map;
        import std.exception : enforce;
        import std.file : exists, isFile, timeLastModified;

        if (!targetPath.length) return false;

        if (!exists(targetPath) || !isFile(targetPath)) {
            return false;
        }

        const targetTime = timeLastModified(targetPath);

        foreach (sf; srcFiles.map!(f => dirs.src(f))) {
            enforce(exists(sf) && isFile(sf), sf~": No such file!");

            if (timeLastModified(sf) > targetTime) {
                return false;
            }
        }
    }
}

Target fileTarget(string target, string[] srcFiles=null)
{
    return new FileTarget(target, srcFiles);
}

Target libTarget(string target, string[] srcFiles=null)
{
    return new LibTarget(target, srcFiles);
}

private:

class FileTarget : Target
{
    this(string target, string[] srcFiles)
    {
        super(target, srcFiles);
    }

    override void resolveTargetPath(in string installDir)
    {
        import std.path : buildPath;

        targetPath = buildPath(installDir, target);
    }
}

class LibTarget : Target
{
    this (string target, string[] srcFiles)
    {
        super(target, srcFiles);
    }

    override void resolveTargetPath(in string installDir)
    {
        // looking for a file that can be a library of name "target"
        // e.g. libtarget.a, libtarget.so, target.lib, etc.
        import std.file : exists, isFile;
        import std.path : buildPath;

        const libtargeta = "lib"~target~".a";
        version(Posix) {
            const libtargetso = "lib"~target~".so";
        }
        else version(Windows) {
            const targetlib = target~".lib";
            const targetdll = target~".dll";
        }
        else {
            static assert(false);
        }

        bool testFile(in string dir, in string name) {
            const path = buildPath(dir, name);
            if (exists(path) && isFile(path)) {
                targetPath = path;
                return true;
            }
            else {
                return false;
            }
        }

        bool searchDir(in string dir) {
            if (!exists(dir)) return false;
            if (testFile(dir, libtargeta)) return true;
            version(Posix) {
                if (testFile(dir, libtargetso)) return true;
            }
            else {
                if (testFile(dir, targetlib)) return true;
                if (testFile(dir, targetdll)) return true;
            }
            return false;
        }

        if (searchDir(installDir)) return true;
        if (searchDir(buildPath(installDir, "lib"))) return true;
        if (searchDir(buildPath(installDir, "lib64"))) return true;
    }
}
