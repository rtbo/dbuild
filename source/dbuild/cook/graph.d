/// A graph is the actual building graph that is built for a given
/// recipe depending of what needs to be updated
module dbuild.cook.graph;

package:

import dbuild.cook.log;
import dbuild.cook.recipe;

import std.datetime : SysTime;
import std.stdio;

class Node
{
    enum State {
        unknown,
        notExist,
        dirty,
        upToDate,
    }

    private this (BuildGraph graph, in string path) {
        this._graph = graph;
        this._path = path;
    }

    @property string path() const {
        return _path;
    }

    @property State state() const {
        return _state;
    }

    @property long mtime() const {
        return _mtime;
    }

    @property Edge inEdge() {
        return _inEdge;
    }

    @property Edge[] outEdges() {
        return _outEdges;
    }

    void checkState(CmdLog cmdLog)
    out (; state != State.unknown)
    {
        import std.exception : enforce;
        import std.file : exists, timeLastModified;

        if (!inEdge) {
            enforce(exists(_path), path ~ " does not exist and there is no recipe to build it!");
            _mtime = timeLastModified(_path).stdTime;
            _state = State.upToDate;
            return;
        }

        if (!exists(path)) {
            _state = State.notExist;
            return;
        }

        _mtime = timeLastModified(_path).stdTime;

        auto entry = cmdLog.entry(_path);
        if (entry && entry.deps.length) {
            // add dependencies to the graph as implicit input
            _inEdge.addImplicitInputs(entry.deps);
        }

        long mostRecentInput;
        foreach (n; inEdge.updateOnlyInputs) {
            n.checkStateIfNeeded(cmdLog);
            if (n.needsRebuild || n.mtime > mtime) {
                _state = State.dirty;
                return;
            }
            if (mostRecentInput < n.mtime) mostRecentInput = n.mtime;
        }

        if (entry) {
            const hash = _inEdge.cmdHash;
            if (hash != entry.hash || mostRecentInput > entry.mtime) {
                // if command has changed or if last build is older than most recent input
                _state = State.dirty;
            }
            else {

                _state = State.upToDate;
            }
        }
        else {
            _state = State.dirty;
        }
    }

    void checkStateIfNeeded(CmdLog cmdLog)
    {
        if (state == State.unknown) {
            checkState(cmdLog);
        }
    }

    @property bool needsRebuild()
    {
        return _state == State.notExist || _state == State.dirty;
    }

    void postBuild(CmdLog cmdLog, in string[] deps)
    in (_inEdge !is null)
    {
        import std.exception : enforce;
        import std.file : exists, timeLastModified;

        enforce(exists(_path));
        _mtime = timeLastModified(_path).stdTime;

        const hash = _inEdge.cmdHash;
        const entry = CmdLog.Entry(_mtime, hash, deps);
        cmdLog.setEntry(_path, entry);

        _state = State.upToDate;
    }

private:

    BuildGraph _graph;
    string _path;
    State _state;
    long _mtime;

    Edge _inEdge;
    Edge[] _outEdges;
}


class Edge
{
    enum State
    {
        // state not queried yet
        unknown,
        // edge must be built
        mustBuild,
        // edge must be built and is identified as ready for building
        // (meaning all inputs are available and up-to-date)
        ready,
        // build is started but not completed
        inProgress,
        // build is completed
        completed,
    }

    private this(BuildGraph graph)
    {
        _graph = graph;
    }

    /// index of this edge in BuildGraph.edges array
    @property size_t ind() const {
        return _ind;
    }

    /// the rule to build outputs from inputs
    @property Rule rule() const {
        return _rule;
    }

    /// number of parallel jobs consumed by this edge
    @property uint jobs() const {
        return _jobs > 0 ? _jobs : rule.jobs;
    }

    @property State state() const {
        return _state;
    }

    @property inout(Node)[] allInputs() inout {
        return _allInputs;
    }
    @property inout(Node)[] inputs() inout {
        return _inputs;
    }
    @property inout(Node)[] implicitInputs() inout {
        return _implicitInputs;
    }
    @property inout(Node)[] orderOnlyInputs() inout {
        return _orderOnlyInputs;
    }

    @property Node[] updateOnlyInputs() {
        return allInputs[0 .. inputs.length+implicitInputs.length];
    }


    @property inout(Node)[] allOutputs() inout {
        return _allOutputs;
    }
    @property inout(Node)[] outputs() inout {
        return _outputs;
    }
    @property inout(Node)[] implicitOutputs() inout {
        return _implicitOutputs;
    }

    // linked list for cook plan ready edges
    package Edge prev;
    package Edge next;

    override string toString()
    {
        import std.algorithm : map;
        import std.conv : to;

        return outputs.map!(n => n.path).to!string;
    }

    @property string command()
    {
        if (!_ruleTranslated) translateRule();
        return rule.command;
    }

    @property string description()
    {
        if (!_ruleTranslated) translateRule();
        return rule.description;
    }

    @property ulong cmdHash()
    {
        if (!_ruleTranslated) translateRule();
        if (rule.command) {
            import std.digest.crc : crc64ECMAOf;
            const crc = crc64ECMAOf(rule.command);
            return *(cast(const(ulong)*)&crc[0]);
        }
        else {
            assert(false);
        }
    }

    @property string depfile()
    {
        if (!_ruleTranslated) translateRule();
        return rule.depfile;
    }

    package @property void state(State state)
    {
        _state = state;
    }

private:

    void translateRule()
    {
        _rule._command = processString(rule.command);
        _rule._description = processString(rule.description);
        _rule._depfile = processString(rule.depfile);
        _ruleTranslated = true;
    }

    string processString(string str)
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

                    res ~= getBinding(varName);
                    varName.length = 0;
                    dollar = false;
                }
            }
            res ~= c;
        }
        if (varName.length) {
            res ~= getBinding(varName);
        }

        return res;
    }

    string getBinding(string key)
    {
        import std.algorithm : map;
        import std.array : join;
        import std.exception : enforce;

        switch (key) {
        case "in":
            return inputs.map!(i => escapePath(i.path)).join(" ");
        case "out":
            return outputs.map!(o => escapePath(o.path)).join(" ");
        default:
            auto p = key in _edgeBindings;
            if (p) return *p;
            p = key in _graphBindings;
            if (p) return *p;
            return null;
        }
    }

    void addImplicitInputs(in string[] deps)
    {
        import std.algorithm : canFind, map;
        import std.array : insertInPlace;

        foreach (d; deps)
        {
            if (updateOnlyInputs.map!"a.path".canFind(d)) continue;

            auto dnp = d in _graph.nodes;
            Node dn;
            if (dnp) {
                dn = *dnp;
            }
            else {
                dn = new Node(_graph, d);
                _graph.nodes[d] = dn;
            }

            dn._outEdges ~= this;

            const size_t ooi = _allInputs.length - _orderOnlyInputs.length;
            const size_t ii = ooi - _implicitInputs.length;

            insertInPlace(_allInputs, ooi, dn);

            _implicitInputs = _allInputs[ii .. ooi+1];
            _orderOnlyInputs = _allInputs[ooi+1 .. $];
        }
    }

    BuildGraph _graph;
    size_t _ind;
    State _state;
    Rule _rule;
    uint _jobs;

    Node[] _allInputs;
    Node[] _inputs;
    Node[] _implicitInputs;
    Node[] _orderOnlyInputs;

    Node[] _allOutputs;
    Node[] _outputs;
    Node[] _implicitOutputs;

    string[string] _graphBindings;
    string[string] _edgeBindings;
    bool _ruleTranslated;
}

private string escapePath (in string path)
{
    import std.array : replace;

    return path.replace(` `, `\ `).replace(`"`, `\"`);
}

class BuildGraph
{
    this (Recipe recipe)
    {
        import std.exception : enforce;

        this.bindings = recipe.bindings;

        Rule[string] rules;

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
                    auto n = new Node(this, p);
                    nn[i] = n;
                    nodes[p] = n;
                }
            }
        }

        edges.reserve(recipe.builds.length);

        foreach (ref b; recipe.builds) {
            auto edge = new Edge(this);
            edge._ind = edges.length;
            edge._rule = rules[b.rule];
            edge._jobs = b.jobs;
            enforce(edge.jobs > 0, "cannot have jobs == 0");
            edge._edgeBindings = b.bindings;
            edge._graphBindings = bindings;

            const i = b.inputs.length;
            const ii = b.implicitInputs.length;
            const ooi = b.orderOnlyInputs.length;
            const o = b.outputs.length;
            const io = b.implicitOutputs.length;

            edge._allInputs = new Node[ i + ii + ooi ];
            edge._allOutputs = new Node[ o + io ];
            edge._inputs = edge.allInputs[ 0 .. i ];
            edge._implicitInputs = edge.allInputs[ i .. i+ii ];
            edge._orderOnlyInputs = edge.allInputs[ i+ii .. i+ii+io ];
            edge._outputs = edge.allOutputs[ 0 .. o ];
            edge._implicitOutputs = edge.allOutputs[ o .. o+io ];

            fillNodes(b.inputs, edge._inputs);
            fillNodes(b.implicitInputs, edge._implicitInputs);
            fillNodes(b.orderOnlyInputs, edge._orderOnlyInputs);
            fillNodes(b.outputs, edge._outputs);
            fillNodes(b.implicitOutputs, edge._implicitOutputs);

            foreach (n; edge.allInputs) {
                n._outEdges ~= edge;
            }
            foreach (n; edge.allOutputs) {
                import std.exception : enforce;

                enforce(n.inEdge is null, "more than one build for the same output: "~n.path);
                n._inEdge = edge;
            }

            edges ~= edge;
        }
    }

    Node[string] nodes;
    Edge[] edges;
    string[string] bindings;
}
