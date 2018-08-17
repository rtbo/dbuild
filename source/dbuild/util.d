module dbuild.util;

package:

import std.digest : isDigest;
import std.traits : isIntegral;
import core.time : dur, Duration;

void feedDigestData(D)(ref D digest, in string s)
if (isDigest!D)
{
    digest.put(cast(ubyte[])s);
    digest.put(0);
}

void feedDigestData(D)(ref D digest, in string[] ss)
if (isDigest!D)
{
    import std.bitmanip : nativeToLittleEndian;
    
    digest.put(nativeToLittleEndian(cast(uint)ss.length));
    foreach (s; ss) {
        digest.put(cast(ubyte[])s);
        digest.put(0);
    }
}

void feedDigestData(D, V)(ref D digest, in V val)
if (isDigest!D && (is(V == enum) || isIntegral!V))
{
    import std.bitmanip : nativeToLittleEndian;

    digest.put(nativeToLittleEndian(val));
    digest.put(0);
}

string makePath(S...)(S comps)
{
    import std.array : array;
    import std.exception : assumeUnique;
    import std.path : chainPath;

    return assumeUnique(chainPath(comps).array);
}

/**
   Obtain a lock for a file at the given path. If the file cannot be locked
   within the given duration, an exception is thrown.  The file will be created
   if it does not yet exist. Deleting the file is not safe as another process
   could create a new file with the same name.
   The returned lock will get unlocked upon destruction.

   Params:
     path = path to file that gets locked
     timeout = duration after which locking failed
   Returns:
     The locked file or an Exception on timeout.
*/
auto lockFile(string path, Duration timeout=dur!"msecs"(500))
{
    import core.thread : Thread;
    import std.algorithm : move;
    import std.datetime : Clock;
    import std.exception : enforce;
    import std.stdio : File;

    // Just a wrapper to hide (and destruct) the locked File.
    static struct LockFile
    {
        // The Lock can't be unlinked as someone could try to lock an already
        // opened fd while a new file with the same name gets created.
        // Exclusive filesystem locks (O_EXCL, mkdir) could be deleted but
        // aren't automatically freed when a process terminates, see dub#1149.
        private File f;
    }

    auto file = File(path, "w");
    auto t0 = Clock.currTime();
    auto duration = dur!"msecs"(1);
    while (true)
    {
        if (file.tryLock())
            return LockFile(move(file));
        enforce(Clock.currTime() - t0 < timeout, "Failed to lock '"~path~"'.");
        if (duration < dur!"msecs"(1024)) // exponentially increase sleep time
            duration *= 2;
        Thread.sleep(duration);
    }
}

void runCommand(string command, string workDir = null, bool quiet = false, string[string] env = null)
{
    runCommands((&command)[0 .. 1], workDir, quiet, env);
}

void runCommands(in string[] commands, string workDir = null, bool quiet = false, string[string] env = null)
{
    import std.conv : to;
    import std.exception : enforce;
    import std.process : Config, Pid, spawnShell, wait;
    import std.stdio : stdin, stdout, stderr, File;

    version(Windows) enum nullFile = "NUL";
    else version(Posix) enum nullFile = "/dev/null";
    else static assert(0);

    auto childStdout = stdout;
    auto childStderr = stderr;
    auto config = Config.retainStdout | Config.retainStderr;

    if (quiet) {
        childStdout = File(nullFile, "w");
    }

    foreach(cmd; commands){
        if (!quiet) {
            stdout.writeln("running ", cmd);
        }
        auto pid = spawnShell(cmd, stdin, childStdout, childStderr, env, config, workDir);
        auto exitcode = pid.wait();
        enforce(exitcode == 0, "Command failed with exit code "
            ~ to!string(exitcode) ~ ": " ~ cmd);
    }
}
