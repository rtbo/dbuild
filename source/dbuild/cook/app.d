module dbuild.cook.app;

version(CookApp):

int main (string[] args)
{
    import std.file : exists, getcwd, isFile;
    import std.format : format;
    import std.getopt : defaultGetoptFormatter, defaultGetoptPrinter, getopt;
    import std.path : buildNormalizedPath, buildPath;

    immutable intro = "Chef Build System - Recipe cooker";
    immutable usageIntro = format(`
Usage: %s [options] [target]

Options:`, args.length ? args[0] : "cook"
    );

    string recipeFile;

    auto opts = getopt(args,
        "recipe|r", "Specify the recipe file to use [$CWD/cook.recipe]", &recipeFile
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

    if (!recipeFile) {
        recipeFile = buildPath(getcwd(), "cook.recipe");
    }
    if (!exists(recipeFile) && isFile(recipeFile)) {
        return error(recipeFile~": No such file.");
    }

    try {
        import dbuild.cook : cookRecipe;
        import dbuild.cook.recipe : loadFromFile, rebasePaths;
        import std.path : absolutePath, dirName;

        auto recipe = loadFromFile(recipeFile);

        const curBase = buildNormalizedPath(absolutePath(dirName(recipeFile)));
        const newBase = buildNormalizedPath(getcwd());
        if (curBase != newBase) {
            recipe.rebasePaths(curBase, newBase);
        }

        cookRecipe(recipe);

        return 0;
    }
    catch (Exception ex) {
        import std.stdio : stderr;

        stderr.writefln("Error occured: %s\n", ex.msg);

        return 2;
    }
}
