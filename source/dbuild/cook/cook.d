module dbuild.cook.cook;

import dbuild.cook.deps;
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
        plan.close();
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

    void rm (in string path)
    {
        if (exists(path)) {
            remove(path);
            const dir = dirName(path);
            if (dirEntries(dir, SpanMode.shallow).empty) {
                rmdir(dir);
            }
        }
    }

    foreach (k, n; graph.nodes) {
        if (n.inEdge) {
            rm(n.path);
            const df = n.inEdge.depfile;
            if (df.length) rm(df);
        }
    }

    rm (buildPath(recipe.cacheDir, cmdsLogFile));
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

string escapeString (in string str)
{
    import std.array : replace;

    return str.replace(`\`, `\\`).replace(` `, `\ `).replace(`"`, `\"`);
}


private:

class BuildPlan
{
    this (BuildGraph graph, Recipe recipe)
    {
        import std.path : buildPath;

        this.graph = graph;
        this.recipe = recipe;
        this.cmdLog = new CmdLog(buildPath(recipe.cacheDir, cmdsLogFile));
    }

    void close()
    {
        cmdLog.close();
    }

    void addTarget(Node target)
    {
        target.checkState(cmdLog);
        if (target.needsRebuild) {
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

        while (readyFirst) {

            auto e = readyFirst;

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
                removeReady(edge);
                edge.state = Edge.State.completed;
                if (ec.output.length) {
                    writefln("%s\n%s", ec.rule.cmd, ec.output);
                }

                foreach (o; edge.allOutputs) {
                    // o.state = Node.State.upToDate;
                    o.postBuild(cmdLog, ec.deps);

                    foreach (e; o.outEdges.filter!(e => e.state == Edge.State.mustBuild)) {
                        if (e.updateOnlyInputs.all!(i => !i.needsRebuild)) {
                            addReady(e);
                            e.state = Edge.State.ready;
                        }
                    }
                }
            }

            void failure (EdgeFailed ef)
            {
                auto edge = graph.edges[ef.ind];
                throw new BuildFailedException(edge.description, ef.rule.cmd, ef.output, ef.code);
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
            n.checkStateIfNeeded(cmdLog);
            if (n.needsRebuild && n.inEdge.state == Edge.State.unknown) {
                // edge not yet visited
                addEdgeToPlan(n.inEdge);
                hasDepRebuild = true;
            }
        }

        if (!hasDepRebuild) {
            addReady(edge);
            edge.state = Edge.State.ready;
        }
    }

    void addReady(Edge edge)
    {
        assert (!isReady(edge));

        if (!readyFirst) {
            assert(!readyLast);
            readyFirst = edge;
            readyLast = edge;
        }
        else {
            readyLast.next = edge;
            edge.prev = readyLast;
            readyLast = edge;
        }
    }

    bool isReady(Edge edge) {
        auto e = readyFirst;
        while (e) {
            if (e is edge) {
                return true;
            }
            e = e.next;
        }
        return false;
    }

    void removeReady(Edge edge)
    {
        assert(isReady(edge));

        if (readyFirst is readyLast) {
            assert(readyFirst is edge);
            readyFirst = null;
            readyLast = null;
        }
        else if (edge is readyFirst) {
            readyFirst = edge.next;
            readyFirst.prev = null;
        }
        else if (edge is readyLast) {
            readyLast = edge.prev;
            readyLast.next = null;
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
            spawn(&runEdgeCommand, thisTid, edge.ind, CmdRule(edge.rule));
        }
    }

    BuildGraph graph;
    Recipe recipe;
    CmdLog cmdLog;
    Node[] targets;
    Edge readyFirst;
    Edge readyLast;
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

struct CmdRule
{
    this(Rule rule) {
        assert(rule.command.length);
        name = rule.name;
        cmd = rule.command;
        depfile = rule.depfile;
        deps = rule.deps;
    }

    string name;
    string cmd;
    string depfile;
    Deps deps;
}

struct EdgeCompleted
{
    size_t ind;
    string output;
    CmdRule rule;
    immutable(string)[] deps;
}

struct EdgeFailed
{
    size_t ind;
    int code;
    string output;
    CmdRule rule;
}

void runEdgeCommand(Tid owner, size_t edgeInd, in CmdRule rule)
{
    import std.concurrency : send;
    import std.exception : enforce;
    import std.process : pipe, spawnProcess, wait;
    import std.typecons : Yes;

    string outBuf;
    const cmd = splitCommand(rule.cmd);

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

        string[] deps;
        switch (rule.deps) {
        case Deps.gcc:
            enforce(rule.depfile, rule.name ~ ": deps gcc must be with a depfile");
            deps = readMkDepFile(rule.depfile);
            break;
        default:
            break;
        }

        if (code) {
            send(owner, EdgeFailed(edgeInd, code, outBuf, rule));
        }
        else {
            import std.exception : assumeUnique;
            send(owner, EdgeCompleted(edgeInd, outBuf, rule, assumeUnique(deps)));
        }
    }
    catch (Exception ex) {
        send(owner, EdgeFailed(edgeInd, 0, ex.msg, rule));
    }
}
