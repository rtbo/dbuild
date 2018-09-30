module dbuild.chef.app;

version(ChefApp):

int main (string[] args)
{
    import std.getopt : defaultGetoptFormatter, defaultGetoptPrinter, getopt;
    import std.file : exists, isDir, isFile;
    import std.format : format;
    import std.path : buildNormalizedPath;

    immutable intro = "Chef Build System";
    immutable usageIntro = format(`
Usage: %s [options] src-folder

Options:`, args.length ? args[0] : "chef-build"
    );

    string luaFile;
    string[string] bindings;
    string buildFolder;
    string installFolder;
    bool cook;

    auto opts = getopt(args,
        "input|l", "Lua input file to process [src-folder/chef.lua]", &luaFile,
        "build|o", "Build folder to write the recipe to [.]", &buildFolder,
        "install|i", "Perform install in specified folder", &installFolder,
        "bind|b", "Specify multiple times to add global bindings to the lua script", &bindings,
        "cook|c", "Perform cook directly after generation", &cook,
    );

    if (opts.helpWanted) {
        defaultGetoptPrinter(intro~usageIntro, opts.options);
        return 0;
    }

    int error(string msg)
    {
        import std.stdio : stderr;
        import std.array : appender;

        auto output = appender(format("Error: %s\n", msg));
        defaultGetoptFormatter(output, usageIntro, opts.options);

        stderr.write(output.data);
        return 1;
    }

    if (!luaFile) {
        if (args.length < 2) {
            return error("Must specify src-folder.");
        }
        luaFile = buildNormalizedPath(args[1], "chef.lua");
    }
    if (!exists(luaFile) || !isFile(luaFile)) {
        return error(luaFile~": No such file.");
    }

    if (!buildFolder) {
        buildFolder = ".";
    }
    buildFolder = buildNormalizedPath(buildFolder);
    if (!exists(buildFolder)) {
        import std.file : mkdirRecurse;
        mkdirRecurse(buildFolder);
    }

    try {
        import dbuild.chef : Chef;
        import dbuild.chef.lua : LuaInterface;
        import dbuild.cook.recipe : writeToFile;
        import std.path : absolutePath, buildPath, dirName, relativePath;

        const srcDir = buildNormalizedPath(absolutePath(dirName(luaFile)));

        auto lua = new LuaInterface;
        auto proj = lua.runFile(
            luaFile,
            relativePath(srcDir, absolutePath(buildFolder))
        );
        auto chef = new Chef(proj);
        chef.setDirs(buildFolder, installFolder);
        auto recipe = chef.buildRecipe();

        writeToFile(recipe, buildPath(buildFolder, "cook.recipe"));

        if (cook) {
            import dbuild.cook : cookRecipe;
            import std.file : chdir, getcwd;

            const cwd = getcwd();
            chdir(buildFolder);
            scope(exit) chdir(cwd);

            cookRecipe(recipe);
        }

        return 0;
    }
    catch (Exception ex) {
        import std.stdio : stderr;
        stderr.writefln("Error occured: %s\n", ex.msg);
        return 2;
    }
}
