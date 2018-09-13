module dbuild.cook.cook;

import dbuild.cook.graph;
import dbuild.cook.log;
import dbuild.cook.recipe;

import std.concurrency : Tid;
import std.parallelism : totalCPUs;
import std.stdio;

/// Build the recipe using maxJobs parallel CPU jobs.
/// If outputs is not null, only these targets and their dependencies are built.
void cookRecipe(Recipe recipe, string[] outputs=null, in uint maxJobs = totalCPUs)
{
    import std.algorithm : canFind;

    auto graph = new BuildGraph(recipe);
    auto plan = new BuildPlan(graph, recipe);
    scope(exit) {
        plan.cmdLog.writeDown();
    }

    foreach (k, n; graph.nodes) {
        if (!n.outEdges.length) {
            if (!outputs.length || outputs.canFind(n.path)) {
                plan.addTarget(n);
            }
        }
    }

    plan.build(maxJobs);
}

/// Clean the recipe by deleting all output files of all builds.
/// Directories of these files that become empty are also deleted.
void cleanRecipe(Recipe recipe)
{
    import std.file : dirEntries, exists, remove, rmdir, SpanMode;
    import std.path : buildPath, dirName;

    auto graph = new BuildGraph(recipe);

    foreach (k, n; graph.nodes) {
        if (n.inEdge && exists(n.path)) {
            remove(n.path);
            const dir = dirName(n.path);
            if (dirEntries(dir, SpanMode.shallow).empty) {
                rmdir(dir);
            }
        }
    }

    const cd = recipe.cacheDir;
    const logpath = buildPath(recipe.cacheDir, ".cook_log");

    if (exists(logpath)) {
        remove(logpath);
    }

    if (dirEntries(cd, SpanMode.shallow).empty) {
        rmdir(cd);
    }
}

/// Exception thrown when a build fails to complete
class BuildFailedException : Exception
{
    string desc;
    string cmd;
    string output;
    int code;

    private this (string desc, string cmd, string output, int code)
    {
        import std.conv : to;

        this.desc = desc;
        this.cmd = cmd;
        this.output = output;
        this.code = code;

        string msg = "\n" ~ desc ~ " failed";
        if (code) msg ~= " with code " ~ code.to!string;
        msg ~= ":\n";

        if (cmd.length) {
            msg ~= cmd ~ "\n";
        }
        if (output.length) {
            msg ~= output ~ "\n";
        }

        super( msg );
    }
}

private:

class BuildPlan
{
    this (BuildGraph graph, Recipe recipe)
    {
        import std.path : buildPath;

        this.graph = graph;
        this.recipe = recipe;
        this.cmdLog = new CmdLog(buildPath(recipe.cacheDir, ".cook_log"));
    }

    void addTarget(Node target)
    {
        if (target.needsRebuild(cmdLog)) {
            targets ~= target;
            addEdgeToPlan(target.inEdge);
        }
    }

    void build(in uint maxJobs)
    {
        import core.time : dur;
        import std.algorithm : all, filter;
        import std.concurrency : receive, receiveTimeout;
        import std.exception : enforce;
        import std.stdio : writefln;

        uint jobs;

        while (availFirst) {

            auto e = availFirst;

            while (e && jobs < maxJobs) {
                if (e.state != Edge.State.inProgress) {
                    jobs += e.jobs;
                    buildEdge(e);
                }
                e = e.next;
            }

            void completion (EdgeCompleted ec)
            {
                auto edge = graph.edges[ec.ind];
                jobs -= edge.jobs;
                removeAvailable(edge);
                edge.state = Edge.State.completed;
                if (ec.output.length) {
                    writefln("%s\n%s", ec.cmd, ec.output);
                }

                foreach (o; edge.allOutputs) {
                    // o.state = Node.State.upToDate;
                    o.postBuild(cmdLog);

                    foreach (e; o.outEdges.filter!(e => e.state == Edge.State.mustBuild)) {
                        if (e.updateOnlyInputs.all!(i => !i.needsRebuild(cmdLog))) {
                            addAvailable(e);
                            e.state = Edge.State.available;
                        }
                    }
                }
            }

            void failure (EdgeFailed ef)
            {
                auto edge = graph.edges[ef.ind];
                throw new BuildFailedException(edge.description, ef.cmd, ef.output, ef.code);
            }

            // must wait for at least one job
            receive(&completion, &failure);
            // purge all that are already waiting
            while(receiveTimeout(dur!"msecs"(-1), &completion, &failure)) {}
        }
    }

private:

    void addEdgeToPlan(Edge edge)
    {
        edge.state = Edge.State.mustBuild;
        ++edgeCount;

        bool hasDepRebuild;

        foreach (n; edge.allInputs) {
            if (n.needsRebuild(cmdLog) && n.inEdge.state == Edge.State.unknown) {
                // edge not yet visited
                addEdgeToPlan(n.inEdge);
                hasDepRebuild = true;
            }
        }

        if (!hasDepRebuild) {
            addAvailable(edge);
            edge.state = Edge.State.available;
        }
    }

    void addAvailable(Edge edge)
    {
        assert (!isAvailable(edge));

        if (!availFirst) {
            assert(!availLast);
            availFirst = edge;
            availLast = edge;
        }
        else {
            availLast.next = edge;
            edge.prev = availLast;
            availLast = edge;
        }
    }

    bool isAvailable(Edge edge) {
        auto e = availFirst;
        while (e) {
            if (e is edge) {
                return true;
            }
            e = e.next;
        }
        return false;
    }

    void removeAvailable(Edge edge)
    {
        assert(isAvailable(edge));

        if (availFirst is availLast) {
            assert(availFirst is edge);
            availFirst = null;
            availLast = null;
        }
        else if (edge is availFirst) {
            availFirst = edge.next;
            availFirst.prev = null;
        }
        else if (edge is availLast) {
            availLast = edge.prev;
            availLast.next = null;
        }
        else {
            auto prev = edge.prev;
            auto next = edge.next;
            prev.next = next;
            next.prev = prev;
        }
        edge.next = null;
        edge.prev = null;
    }


    void buildEdge(Edge edge)
    {
        import std.algorithm : map;
        import std.concurrency : spawn, thisTid;
        import std.exception : enforce;
        import std.file : mkdirRecurse;
        import std.path : dirName;
        import std.stdio : writefln;

        edge.state = Edge.State.inProgress;

        writeln(edge.description);

        foreach (n; edge.allOutputs) {
            mkdirRecurse(dirName(n.path));
        }

        if (!edge.command) {
            //enforce(!rule.command.length, rule.name ~ " rule must have either command or commandDg");
            // TODO
        }
        else {
            enforce(edge.command.length, edge.rule.name ~ " rule must have either command or commandDg");
            spawn(&runEdgeCommand, thisTid, edge.ind, edge.command);
        }
    }

    BuildGraph graph;
    Recipe recipe;
    CmdLog cmdLog;
    Node[] targets;
    Edge availFirst;
    Edge availLast;
    int edgeCount;
}

string[] splitCommand(in string cmd)
{
    import std.ascii : isWhite;

    string[] res;
    string arg;
    bool quote;
    bool escape;

    foreach (char c; cmd) {
        if (c.isWhite && !quote && !escape) {
            if (arg.length) {
                res ~= arg;
                arg = null;
            }
        }
        else if (c == '"' && !escape) {
            quote = !quote;
        }
        else if (c == '\\' && !escape) {
            escape = true;
        }
        else if (c.isWhite && (quote || escape)) {
            arg ~= c;
        }
        else {
            escape = false;
            arg ~= c;
        }
    }

    if (arg.length) res ~= arg;

    return res;
}

unittest
{
    assert(splitCommand(`exe $1  $2`) == [`exe`, `$1`, `$2`]);
    assert(splitCommand(`exe $1\ again  $2`) == [`exe`, `$1 again`, `$2`]);
    assert(splitCommand(`exe "$1 again"  $2`) == [`exe`, `$1 again`, `$2`]);
    assert(splitCommand(`exe $1\"  $2`) == [`exe`, `$1"`, `$2`]);
    assert(splitCommand(`exe "$1\" again"  $2`) == [`exe`, `$1" again`, `$2`]);
}

void runEdgeCommand(Tid owner, size_t edgeInd, in string cmdStr)
{
    import std.concurrency : send;
    import std.process : pipe, spawnProcess, wait;
    import std.typecons : Yes;

    string outBuf;
    const cmd = splitCommand(cmdStr);

    try {
        version(Posix) {
            auto nul = File("/dev/null", "r");
        }
        else version (Windows) {
            auto nul = File("NUL", "r");
        }
        else {
            static assert(false);
        }
        auto p = pipe();
        auto pid = spawnProcess(cmd, nul, p.writeEnd, p.writeEnd);

        foreach (l; p.readEnd.byLine(Yes.keepTerminator)) {
            outBuf ~= l.idup;
        }

        int code = wait(pid);

        if (code) {
            send(owner, EdgeFailed(edgeInd, code, outBuf, cmdStr));
        }
        else {
            send(owner, EdgeCompleted(edgeInd, outBuf, cmdStr));
        }
    }
    catch (Exception ex) {
        send(owner, EdgeFailed(edgeInd, 0, outBuf, cmdStr));
    }

}

void sleepJob(Tid owner, size_t edgeInd, uint msecs)
{
    import core.thread : Thread;
    import core.time : dur;
    import std.concurrency : send;

    Thread.sleep(dur!"msecs"(msecs));
    send(owner, EdgeCompleted(edgeInd));
}

struct EdgeCompleted
{
    size_t ind;
    string output;
    string cmd;
}

struct EdgeFailed
{
    size_t ind;
    int code;
    string output;
    string cmd;
}
