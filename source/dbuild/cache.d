module dbuild.cache;

package:

struct Cache
{
    import std.json : JSONValue;
    import std.stdio : File;

    this(in string workDir)
    {
        import std.exception : enforce;
        import std.file : exists, isFile, read;
        import std.json : parseJSON;
        import std.path : buildPath;

        // TODO: do the following atomically (another lock file?)

        const path = buildPath(workDir, "cache.json");
        if (exists(path)) {
            enforce(isFile(path));
            const s = cast(string)read(path);
            _json = parseJSON(s);
        }
        _file = File(path, "w");
        enforce(_file.tryLock(), "Could not lock "~path);
    }

    @disable this(this);

    ~this()
    {
        const s = _json.toString();
        _file.write(s);
        _file.unlock();
    }

    private File _file;
    private JSONValue _json;
}
