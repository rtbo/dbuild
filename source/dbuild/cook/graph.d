/// A graph is the actual building graph that is built for a given
/// recipe depending of what need to be updated
module dbuild.cook.graph;

package:

import dbuild.cook.recipe;

import std.datetime : SysTime;
import std.stdio;

class Node
{
    enum State {
        unknown         = 0,
        notExist        = 1 | needsRebuild,
        dirty           = 2 | needsRebuild,
        upToDate        = 3,
        needsRebuild    = 4,
    }

    this (in string path) {
        this.path = path;
    }

    string path;
    State state;
    SysTime mtime;

    Edge inEdge;
    Edge[] outEdges;

    void checkState()
    out {
        assert(state != State.unknown);
    }
    body {
        import std.exception : enforce;
        import std.file : exists, timeLastModified, getcwd;

        if (!exists(path)) {
            enforce(inEdge !is null, path ~ " does not exist and there is no recipe to build it!");
            state = State.notExist;
            return;
        }
        mtime = timeLastModified(path);
        if (!inEdge) {
            state = State.upToDate;
            return;
        }
        foreach (n; inEdge.updateOnlyInputs) {
            n.checkStateIfNeeded();
            if (n.needsRebuild || n.mtime >= mtime) {
                state = State.dirty;
                return;
            }
        }
        state = State.upToDate;
    }

    void checkStateIfNeeded() {
        if (state == State.unknown) {
            checkState();
        }
    }

    @property bool needsRebuild() const
    in (state != State.unknown)
    {
        return cast(int)(state & State.needsRebuild) != 0;
    }
}


class Edge
{
    enum State
    {
        // state not queried yet
        unknown,
        // edge must be built
        mustBuild,
        // edge must be built and is identified as available for building
        // (meaning all inputs are available)
        available,
        // build is started but not completed
        inProgress,
        // build is completed
        completed,
    }

    /// index of this edge in BuildGraph.edges array
    size_t ind;

    /// the rule to build outputs from inputs
    Rule rule;

    /// number of parallel jobs consumed by this edge
    @property uint jobs() const {
        return _jobs > 0 ? _jobs : rule.jobs;
    }
    private uint _jobs;

    State state;

    Node[] allInputs;
    Node[] inputs;
    Node[] implicitInputs;
    Node[] orderOnlyInputs;

    @property Node[] updateOnlyInputs() {
        return allInputs[0 .. inputs.length+implicitInputs.length];
    }

    Node[] allOutputs;
    Node[] outputs;
    Node[] implicitOutputs;

    string[string] bindings;

    // linked list for available edges
    Edge prev;
    Edge next;

    override string toString()
    {
        import std.algorithm : map;
        import std.format : format;

        return format("%s", outputs.map!(n => n.path));
    }

    void translateRule(BindingStack bindings)
    {
        rule._command = processString(rule.command, bindings);
        rule._description = processString(rule.description, bindings);
    }

private:

    string processString(string str, BindingStack bindings)
    {
        import std.array : join;
        import std.ascii : isAlpha, isAlphaNum;
        import std.exception : enforce;

        string res;
        string varName;
        bool dollar;

        foreach (char c; str) {
            if (c == '$' && dollar && !varName.length) {
                res ~= c;
                dollar = false;
                continue;
            }
            else if (c == '$' && !dollar) {
                dollar = true;
                continue;
            }
            else if (dollar) {
                if ((varName.length && isAlphaNum(c)) || isAlpha(c)) {
                    varName ~= c;
                    continue;
                }
                else {
                    enforce(varName.length, str~": binding with empty name is forbidden");

                    res ~= getBinding(varName, bindings);
                    varName.length = 0;
                    dollar = false;
                }
            }
            res ~= c;
        }
        if (varName.length) {
            res ~= getBinding(varName, bindings);
        }

        return res;
    }

    string getBinding(string key, BindingStack bindings)
    {
        import std.algorithm : map;
        import std.array : join;
        import std.exception : enforce;

        switch (key) {
        case "in":
            return inputs.map!("a.path").join(" ");
        case "out":
            return outputs.map!("a.path").join(" ");
        default:
            return bindings.lookUp(key);
        }
    }

}

class BuildGraph
{
    this(Node[string] nodes, Edge[] edges, string[string] bindings)
    {
        this.nodes = nodes;
        this.edges = edges;
        this.bindings = bindings;
    }

    Node[string] nodes;
    Edge[] edges;
    string[string] bindings;
}

BuildGraph prepareGraph(Recipe recipe)
{
    import std.exception : enforce;

    Rule[string] rules;
    Node[string] nodes;
    Edge[] edges;

    foreach (const ref r; recipe.rules) {
        rules[r.name] = r;
    }

    void fillNodes(in string[] paths, Node[] nn) {
        assert(paths.length == nn.length);
        foreach (i, p; paths) {
            auto np = p in nodes;
            if (np) {
                nn[i] = *np;
            }
            else {
                auto n = new Node(p);
                nn[i] = n;
                nodes[p] = n;
            }
        }
    }

    edges.reserve(recipe.builds.length);

    foreach (ref b; recipe.builds) {
        auto edge = new Edge;
        edge.ind = edges.length;
        edge.rule = rules[b.rule];
        edge._jobs = b.jobs;
        enforce(edge.jobs > 0, "cannot have jobs == 0");
        edge.bindings = b.bindings;

        const i = b.inputs.length;
        const ii = b.implicitInputs.length;
        const ooi = b.orderOnlyInputs.length;
        const o = b.outputs.length;
        const io = b.implicitOutputs.length;

        edge.allInputs = new Node[ i + ii + ooi ];
        edge.allOutputs = new Node[ o + io ];
        edge.inputs = edge.allInputs[ 0 .. i ];
        edge.implicitInputs = edge.allInputs[ i .. i+ii ];
        edge.orderOnlyInputs = edge.allInputs[ i+ii .. i+ii+io ];
        edge.outputs = edge.allOutputs[ 0 .. o ];
        edge.implicitOutputs = edge.allOutputs[ o .. o+io ];

        fillNodes(b.inputs, edge.inputs);
        fillNodes(b.implicitInputs, edge.implicitInputs);
        fillNodes(b.orderOnlyInputs, edge.orderOnlyInputs);
        fillNodes(b.outputs, edge.outputs);
        fillNodes(b.implicitOutputs, edge.implicitOutputs);
        foreach (n; edge.allInputs) {
            n.outEdges ~= edge;
        }
        foreach (n; edge.allOutputs) {
            import std.exception : enforce;

            enforce(n.inEdge is null);
            n.inEdge = edge;
        }

        edges ~= edge;
    }

    return new BuildGraph(nodes, edges, recipe.bindings);
}


class BindingStack
{
    this (string[string] bindings, BindingStack outer=null) {
        this.bindings = bindings;
        this.outer = outer;
    }

    string lookUp(in string key)
    {
        auto b = key in bindings;
        if (b) return *b;
        else if (outer) return outer.lookUp(key);
        else return null;
    }

    string[string] bindings;
    BindingStack outer;
}
