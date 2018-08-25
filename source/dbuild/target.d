module dbuild.target;


/// A target to be checked for, to possibly bypass the build
abstract class Target
{
    /// target name
    string name;
    /// files used to build the artifacts in the src dir
    string[] srcFiles;
    /// full path to the target artifact
    string artifact;

    private this(string name, string[] srcFiles)
    {
        this.name = name;
        this.srcFiles = srcFiles;
    }

    /// resolve the target file in the install dir, and set the targetPath field
    abstract void resolveArtifact(in string installDir);

    /// Check if the target is up-to-date vs the provided src files.
    /// Returns: true if the target is up-to-date, false if it needs rebuild
    bool check(in string srcDir)
    {
        import std.algorithm : map;
        import std.exception : enforce;
        import std.file : exists, isFile, timeLastModified;
        import std.path : buildPath;

        if (!artifact.length) return false;

        if (!exists(artifact) || !isFile(artifact)) {
            return false;
        }

        const artifactTime = timeLastModified(artifact);

        foreach (sf; srcFiles.map!(f => srcDir.buildPath(f))) {
            enforce(exists(sf) && isFile(sf), sf~": No such file!");

            if (timeLastModified(sf) > artifactTime) {
                return false;
            }
        }

        return true;
    }
}

Target fileTarget(string name, string[] srcFiles=null)
{
    return new FileTarget(name, srcFiles);
}

Target libTarget(string name, string[] srcFiles=null)
{
    return new LibTarget(name, srcFiles);
}

private:

class FileTarget : Target
{
    this(string name, string[] srcFiles)
    {
        super(name, srcFiles);
    }

    override void resolveArtifact(in string installDir)
    {
        import std.path : buildPath;

        artifact = buildPath(installDir, name);
    }
}

class LibTarget : Target
{
    this (string name, string[] srcFiles)
    {
        super(name, srcFiles);
    }

    override void resolveArtifact(in string installDir)
    {
        // looking for a file that can be a library of name "target"
        // e.g. libtarget.a, libtarget.so, target.lib, etc.
        import std.algorithm : any, canFind;
        import std.file : exists, isFile;
        import std.range : only;
        import std.path : buildPath;

        bool testFile(in string path) {
            if (exists(path) && isFile(path)) {
                artifact = path;
                return true;
            }
            else {
                return false;
            }
        }

        // the directories and file extensions to look for
        const libDir = buildPath(installDir, "lib");
        const lib64Dir = buildPath(installDir, "lib64");
        const binDir = buildPath(installDir, "bin");

        // if name already has an extension (may be with version behind)
        // we try to look only for exact filename in a few directories
        string[] exts = [".a"];
        version(Posix) {
            exts ~= [".so"];
        }
        else version(Windows) {
            exts ~= [".lib", ".dll"];
        }
        else {
            static assert(false);
        }

        if (exts.any!(e => name.canFind(e))) {
            foreach (sd; only(installDir, libDir, lib64Dir, binDir)) {
                if (testFile(buildPath(sd, name))) break;
            }
            return;
        }

        // testing now for standard names
        const libnamea = "lib"~name~".a";
        auto search = [
            buildPath(libDir, libnamea), buildPath(lib64Dir, libnamea)
        ];
        version(Posix) {
            const libnameso = "lib"~name~".so";
            search ~= [ buildPath(libDir, libnameso), buildPath(lib64Dir, libnameso) ];
        }
        else version(Windows) {
            const namelib = name~".lib";
            const namedll = name~".dll";
            const libnamedlla = "lib"~name~".dll.a";
            search ~= [
                buildPath(libDir, namelib), buildPath(lib64Dir, namelib),
                buildPath(libDir, libnamedlla), buildPath(lib64Dir, libnamedlla),
                buildPath(binDir, namedll)
            ];
        }

        foreach(s; search) {
            if (testFile(s)) break;
        }
    }
}
