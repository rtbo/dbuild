module dbuild.cook.cook;

import dbuild.cook.recipe;
import dbuild.cook.graph;

import std.concurrency : Tid;
import std.parallelism : totalCPUs;
import std.stdio;

void cookRecipe(Recipe recipe, string[] outputs=null, in uint maxJobs = totalCPUs)
{
    import std.algorithm : canFind;

    auto graph = prepareGraph(recipe);

    auto plan = new BuildPlan(graph);

    foreach (k, n; graph.nodes) {
        if (!n.outEdges.length) {
            if (!outputs.length || outputs.canFind(n.path)) {
                plan.addTarget(n);
            }
        }
    }

    plan.build(maxJobs);
}

/// Exception thrown when a build fails to complete
class BuildFailedException : Exception
{
    string desc;
    string stdout;
    string stderr;
    int code;

    private this (Edge edge, int code, string stdout, string stderr)
    {
        import std.conv : to;

        auto rule = edge.rule;

        this.desc = rule.description;
        this.code = code;
        this.stdout = stdout;
        this.stderr = stderr;

        string msg = "\n" ~ desc ~ " failed";
        if (code) msg ~= " with code " ~ code.to!string;
        msg ~= ":\n";

        if (rule.command.length) {
            msg ~= rule.command ~ "\n";
        }
        if (stdout.length) {
            msg ~= stdout ~ "\n";
        }
        if (stderr.length) {
            msg ~= stderr ~ "\n";
        }

        super( msg );
    }
}

private:

class BuildPlan
{
    this (BuildGraph graph) {
        this.graph = graph;
    }

    void addTarget(Node target) {
        target.checkState();
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

        auto bindStack = new BindingStack(graph.bindings);

        uint jobs;

        while (availFirst) {

            auto e = availFirst;

            while (e && jobs < maxJobs) {
                if (e.state != Edge.State.inProgress) {
                    jobs += e.jobs;
                    buildEdge(e, new BindingStack(e.bindings, bindStack));
                }
                e = e.next;
            }

            void completion (EdgeCompleted ec)
            {
                auto edge = graph.edges[ec.ind];
                jobs -= edge.jobs;
                removeAvailable(edge);
                edge.state = Edge.State.completed;

                foreach (o; edge.allOutputs) {
                    o.checkState();
                    // o.state = Node.State.upToDate;
                    enforce(!o.needsRebuild);

                    foreach (e; o.outEdges.filter!(e => e.state == Edge.State.mustBuild)) {
                        if (e.updateOnlyInputs.all!(i => !i.needsRebuild)) {
                            addAvailable(e);
                            e.state = Edge.State.available;
                        }
                    }
                }
            }

            void failure (EdgeFailed ef)
            {
                auto edge = graph.edges[ef.ind];
                throw new BuildFailedException(edge, ef.code, ef.output, ef.error);
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
        bool hasDepRebuild;

        foreach (n; edge.allInputs) {
            n.checkStateIfNeeded();
            hasDepRebuild = n.needsRebuild;
            if (hasDepRebuild && n.inEdge.state == Edge.State.unknown) {
                // edge not yet visited
                addEdgeToPlan(n.inEdge);
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

    BuildGraph graph;
    Node[] targets;
    Edge availFirst;
    Edge availLast;
}

void buildEdge(Edge edge, BindingStack bindStack)
{
    import std.algorithm : map;
    import std.concurrency : spawn, thisTid;
    import std.exception : enforce;
    import std.file : mkdirRecurse;
    import std.path : dirName;
    import std.stdio : writefln;

    edge.state = Edge.State.inProgress;
    edge.translateRule(bindStack);
    auto rule = edge.rule;

    writeln(rule.description);

    foreach (n; edge.allOutputs) {
        mkdirRecurse(dirName(n.path));
    }

    if (rule.commandDg) {
        enforce(!rule.command.length, rule.name ~ " rule must have either command or commandDg");
        // TODO
    }
    else {
        enforce(rule.command.length, rule.name ~ " rule must have either command or commandDg");
        immutable cmd = splitCommand(rule.command);
        spawn(&runEdgeCommand, thisTid, edge.ind, cmd);
    }
}

immutable(string[]) splitCommand(in string cmd)
{
    import std.exception : assumeUnique;
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

    return assumeUnique(res);
}

unittest
{
    assert(splitCommand(`exe $1  $2`) == [`exe`, `$1`, `$2`]);
    assert(splitCommand(`exe $1\ again  $2`) == [`exe`, `$1 again`, `$2`]);
    assert(splitCommand(`exe "$1 again"  $2`) == [`exe`, `$1 again`, `$2`]);
    assert(splitCommand(`exe $1\"  $2`) == [`exe`, `$1"`, `$2`]);
    assert(splitCommand(`exe "$1\" again"  $2`) == [`exe`, `$1" again`, `$2`]);
}

void runEdgeCommand(Tid owner, size_t edgeInd, immutable(string[]) cmd)
{
    import core.thread : Thread;
    import std.concurrency : send;
    import std.process : pipe, spawnProcess, wait;
    import std.stdio : stdin;
    import std.typecons : Yes;

    string outBuf;
    string errBuf;

    try {
        auto outF = pipe();
        auto errF = pipe();

        void exhaustPipe(File readEnd, ref string buf) {
            foreach (l; readEnd.byLine(Yes.keepTerminator)) {
                buf ~= l;
            }
        }

        auto pid = spawnProcess(cmd, stdin, outF.writeEnd, errF.writeEnd);

        // auto th = new Thread(() {
        //     exhaustPipe(outF.readEnd, outBuf);
        // });
        exhaustPipe(errF.readEnd, errBuf);
        // th.join();

        int code = wait(pid);

        if (code) {
            send(owner, EdgeFailed(edgeInd, code, outBuf, errBuf));
        }
        else {
            send(owner, EdgeCompleted(edgeInd, outBuf, errBuf));
        }
    }
    catch (Exception ex) {
        send(owner, EdgeFailed(edgeInd, 0, outBuf, errBuf));
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
    string error;
}

struct EdgeFailed
{
    size_t ind;
    int code;
    string output;
    string error;
}


// private bool needsUpdate(Node node)
// {
//     import std.file : exists, timeLastModified;

//     // primary input, (e.g. source file)
//     if (!node.inEdge) return false;
//     // if file is missing, it needs update
//     if (!exists(node.path)) return true;

//     import std.algorithm : all, map, minElement;
//     if (!all!(exists)())

// }

private bool needsUpdate(Build build)
{
    import std.algorithm : all, map, minElement;
    import std.file : exists, timeLastModified;
    import std.range : chain;

    // if input is missing, it will need update after inputs are regenerated
    if (!all!(exists)(build.outputs
            .chain(build.inputs)
            .chain(build.implicitInputs))) {
        return true;
    }

    // all inputs and outputs are there, checking if they are up-to-date
    const outputTime = minElement(build.outputs.map!(timeLastModified));
    foreach(inputTime; build.inputs.chain(build.implicitInputs).map!(timeLastModified)) {
        if (inputTime > outputTime) return true;
    }

    return false;
}