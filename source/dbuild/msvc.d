module dbuild.msvc;

version(Windows):

struct MsvcInstall
{
    string vcvarsBat;
    ushort[2] ver;
}

MsvcInstall[] detectMsvcInstalls()
{
    MsvcInstall[] res;
    MsvcInstall install;
    if (detectBuildTools2017(install)) {
        res ~= install;
    }
    // TODO: other installs through registry
    return res;
}

string[string] msvcEnvironment(in string vcvarsBat, in string[] options)
{
    import dbuild.util : tempFilePath;
    import std.algorithm : canFind;
    import std.exception : enforce;
    import std.file : remove;
    import std.process : Config, pipe, spawnShell, wait;
    import std.stdio : File, stdin, stderr;

    enum startMark = "__dbuild_start_mark__";
    enum endMark = "__dbuild_end_mark__";

    const scriptPath = tempFilePath("vcenv-%s.bat");
    auto invokeLine = "call \"" ~ vcvarsBat ~ "\"";
    foreach (o; options) invokeLine ~= " " ~ o;

    {
        auto script = File(scriptPath, "w");

        script.writeln("@echo off");
        script.writeln(invokeLine);
        script.writeln("echo " ~ startMark);
        script.writeln("set"); // dump environment variables
        script.writeln("echo " ~ endMark);
    }

    scope(exit) remove(scriptPath);

    string[string] env; 

    auto p = pipe();
    auto childIn = stdin;
    auto childOut = p.writeEnd;
    auto childErr = stderr; //File("NUL", "w");
	// Do not use retainStdout here as the output reading loop would hang forever.
    const config = Config.none;
    auto pid = spawnShell(scriptPath, childIn, childOut, childErr, null, config);
    bool withinMarks;
    foreach (l; p.readEnd.byLine) {
        if (!withinMarks && l.canFind(startMark)) {
            withinMarks = true;
        }
        else if (withinMarks && l.canFind(endMark)) {
            withinMarks = false;
        }
        else if (withinMarks) {
            import std.algorithm : findSplit;
            import std.string : strip;

            auto splt = l.strip().idup.findSplit("=");
            if (splt) {
                env[splt[0]] = splt[2];
            }
        }
    }
    const exitCode = pid.wait();
    enforce(exitCode == 0, "detection of MSVC environment failed");

    return env;
}

private @property string programFilesDir()
{
    import std.process : environment;

    version(Win64) {
        string var = "ProgramFiles(x86)";
    } 
    else {
        string var = "ProgramFiles";
    }
    return environment[var];
}

private bool detectBuildTools2017(out MsvcInstall install)
{
    import std.file : exists;
    import std.path : buildPath;
    
    const pfd = programFilesDir;
    install.vcvarsBat = buildPath(pfd, "Microsoft Visual Studio", "2017", "BuildTools",
            "VC", "Auxiliary", "Build", "vcvarsall.bat");
    
    if (exists(install.vcvarsBat)) {
        install.ver = [15, 0];
        return true;
    }
    else {
        return false;
    }
}
