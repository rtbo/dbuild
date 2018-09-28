module dbuild.cook.recipe;


/// Deps is the format of header/module dependency that can output a compiler
/// if instructed to do so
enum Deps
{
    none, gcc, msvc, dmd
}

/// A delegate that can be used inplace of a process command
alias CommandDg = void delegate(ref string outbuf, ref string errbuf);

/// A Rule expresses how to convert input parts to output parts
struct Rule
{
    @property string name() const {
        return _name;
    }

    @property string description() const {
        return _description;
    }

    @property string command() const {
        return _command;
    }

    @property CommandDg commandDg() const {
        return _commandDg;
    }

    @property string depfile() const {
        return _depfile;
    }

    @property Deps deps() const {
        return _deps;
    }

    @property uint jobs() const {
        return _jobs;
    }

    this (in string name, in string command)
    {
        _name = name;
        _command = command;
    }

    this (in string name, CommandDg commandDg)
    {
        _name = name;
        _commandDg = commandDg;
    }

    Rule withDepfile(in string depfile)
    {
        _depfile = depfile;
        return this;
    }

    Rule withDeps(in Deps deps) {
        _deps = deps;
        return this;
    }

    Rule withDescription(in string description) {
        _description = description;
        return this;
    }

    Rule withJobs(in uint jobs) {
        _jobs = jobs;
        return this;
    }

    package string _name;
    package string _description = "Processing $in";
    package string _command;
    package CommandDg _commandDg;
    package string _depfile;
    package Deps _deps;
    package uint _jobs = 1;
}

/// A Build expresses a specific build: a set of input parts, producing a set
/// of output parts (generally one) using a rule
struct Build
{
    this (in string rule, string[] inputs, string output) {
        _rule = rule;
        _inputs = inputs;
        _outputs = [ output ];
    }

    this (in string rule, string[] inputs, string[] output) {
        _rule = rule;
        _inputs = inputs;
        _outputs = output;
    }

    Build withImplicitOutputs(string[] implicitOutputs) {
        _implicitOutputs = implicitOutputs;
        return this;
    }

    Build withImplicitInputs(string[] implicitInputs) {
        _implicitInputs = implicitInputs;
        return this;
    }

    Build withOrderOnlyInputs(string[] orderOnlyInputs) {
        _orderOnlyInputs = orderOnlyInputs;
        return this;
    }

    Build withBinding(in string binding, in string value) {
        _bindings[binding] = value;
        return this;
    }

    Build withBindings(string[string] bindings) {
        _bindings = bindings;
        return this;
    }

    Build withBindings(Args...)(Args args) {
        static assert(args.length % 2 == 0, "must give pairs of keys and values");
        static foreach (i; 0 .. args.length/2) {
            _bindings[args[i*2]] = args[i*2 + 1];
        }
        return this;
    }

    Build withJobs(in uint jobs) {
        _jobs = jobs;
        return this;
    }

    @property string[] outputs() { return _outputs; }
    @property string[] implicitOutputs() { return _implicitOutputs; }
    @property string rule() { return _rule; }
    @property string[] inputs() { return _inputs; }
    @property string[] implicitInputs() { return _implicitInputs; }
    @property string[] orderOnlyInputs() { return _orderOnlyInputs; }
    @property string[string] bindings() { return _bindings; }
    @property uint jobs() { return _jobs; }

    private string _rule;
    private string[] _outputs;
    private string[] _implicitOutputs;
    private string[] _inputs;
    private string[] _implicitInputs;
    private string[] _orderOnlyInputs;
    private string[string] _bindings;
    private uint _jobs;
}

/// A recipe is a set of rules and builds working together, optionally with
/// toplevel bindings and a cache directory
struct Recipe
{
    /// Set of rules that are used by the builds to describe how to transform
    /// inputs to outputs
    Rule[] rules;
    /// Set of builds describing the dependency graph
    Build[] builds;
    /// Top level bindings. Use this for example to store cflags for default or release builds
    string[string] bindings;
    /// The directory where cook will load and write the cache files.
    /// Defaults to the current working directory if null.
    @property string cacheDir()
    {
        import std.file : getcwd;

        return _cacheDir ? _cacheDir : getcwd();
    }
    private string _cacheDir;

    this(Rule[] rules, Build[] builds)
    {
        this.rules = rules;
        this.builds = builds;
    }


    Recipe withBinding(in string binding, in string value) {
        this.bindings[binding] = value;
        return this;
    }

    Recipe withBindings(string[string] bindings) {
        this.bindings = bindings;
        return this;
    }

    Recipe withBindings(Args...)(Args args) {
        static assert(args.length % 2 == 0, "must give pairs of keys and values");
        static foreach (i; 0 .. args.length/2) {
            this.bindings[args[i*2]] = args[i*2 + 1];
        }
        return this;
    }

    Recipe withCacheDir(in string dir)
    {
        this._cacheDir = dir;
        return this;
    }
}

void writeToFile(Recipe recipe, string filename)
{
    import std.exception : enforce;
    import std.stdio : File;

    auto f = File(filename, "w");
    foreach (r; recipe.rules) {
        enforce(r.commandDg is null, "cannot write rules with delegate");
        f.writeln("rule ", r.name);
        f.writeln("\tdescription ", r.description);
        f.writeln("\tcommand ", r.command);
        if (r.deps != Deps.none)
            f.writeln("\tdeps ", r.deps);
        if (r.depfile.length)
            f.writeln("\tdepfile ", r.depfile);
        if (r.jobs != 1)
            f.writeln("\tjobs ", r.jobs);
        f.writeln();
    }

    void writeArray(in string key, in string[] values) {
        foreach (v; values) {
            f.writefln("\t%s %s", key, v);
        }
    }

    foreach (b; recipe.builds) {
        f.writeln("build ", b.rule);
        writeArray("input", b.inputs);
        writeArray("implicitInput", b.implicitInputs);
        writeArray("orderOnlyInput", b.orderOnlyInputs);
        writeArray("output", b.outputs);
        writeArray("implicitOutput", b.implicitOutputs);
        if (b.jobs != 0) f.writeln("\tjobs ", b.jobs);
        foreach (k, v; b.bindings) {
            if (k.length && v.length)
                f.writefln("\tbinding %s = %s", k, v);
        }
        f.writeln();
    }

    foreach (k, v; recipe.bindings) {
        if (k.length && v.length) {
            f.writefln("binding %s = %s", k, v);
        }
    }

    // take the direct field here, otherwise we get getcwd
    if (recipe._cacheDir.length) {
        f.writefln("cacheDir %s", recipe._cacheDir);
    }
}

class RecipeReadException : Exception
{
    string filename;
    int lineNum;

    this (string filename, int lineNum, string msg)
    {
        this.filename = filename;
        this.lineNum = lineNum;
        super(msg);
    }
}

Recipe loadFromFile(string filename)
{
    import std.algorithm : startsWith;
    import std.conv : to;
    import std.exception : enforce;
    import std.stdio : File;
    import std.string : stripLeft;
    import std.uni : isWhite;

    auto f = File(filename, "r");

    Recipe recipe;
    Rule rule = void;
    Build build = void;
    bool inRule, inBuild;
    int lineNum;

    foreach (l; f.byLineCopy) {
        ++lineNum;
        if (!inRule && !inBuild) {
            if (!l.length) continue;
            if (l.startsWith("rule ")) {
                inRule = true;
                rule = Rule.init;
                rule._name = l["rule ".length .. $];
            }
            else if (l.startsWith("build ")) {
                inBuild = true;
                build = Build.init;
                build._rule = l["build ".length .. $];
            }
            else if (l.startsWith("binding ")) {
                auto b = readBinding(l["binding ".length .. $], filename, lineNum);
                recipe.bindings[b[0]] = b[1];
            }
            else if (l.startsWith("cacheDir ")) {
                recipe._cacheDir = l["cacheDir ".length .. $];
            }
            else {
                throw new RecipeReadException(filename, lineNum, "unexpected input: "~l);
            }
        }
        else if (inRule) {
            if (!l.length) {
                recipe.rules ~= rule;
                inRule = false;
                continue;
            }
            enforce(l[0].isWhite);
            l = l.stripLeft();
            if (l.startsWith("description ")) {
                rule._description = l["description ".length .. $];
            }
            else if (l.startsWith("command ")) {
                rule._command = l["command ".length .. $];
            }
            else if (l.startsWith("depfile ")) {
                rule._depfile = l["depfile ".length .. $];
            }
            else if (l.startsWith("deps ")) {
                rule._deps = l["deps ".length .. $].to!Deps;
            }
            else if (l.startsWith("jobs ")) {
                rule._jobs = l["jobs ".length .. $].to!uint;
            }
            else {
                throw new RecipeReadException(filename, lineNum, "unexpected input: "~l);
            }
        }
        else if (inBuild) {
            if (!l.length) {
                recipe.builds ~= build;
                inBuild = false;
                continue;
            }
            enforce(l[0].isWhite);
            l = l.stripLeft();
            if (l.startsWith("input ")) {
                build._inputs ~= l["input ".length .. $];
            }
            else if (l.startsWith("implicitInput ")) {
                build._implicitInputs ~= l["implicitInput ".length .. $];
            }
            else if (l.startsWith("orderOnlyInput ")) {
                build._orderOnlyInputs ~= l["orderOnlyInput ".length .. $];
            }
            else if (l.startsWith("output ")) {
                build._outputs ~= l["output ".length .. $];
            }
            else if (l.startsWith("implicitOutput ")) {
                build._implicitOutputs ~= l["implicitOutput ".length .. $];
            }
            else if (l.startsWith("binding ")) {
                auto b = readBinding(l["binding ".length .. $], filename, lineNum);
                build._bindings[b[0]] = b[1];
            }
            else if (l.startsWith("jobs ")) {
                build._jobs = l["jobs ".length .. $].to!uint;
            }
        }
    }

    return recipe;
}

private string[2] readBinding(string str, string filename, int lineNum)
{
    import std.algorithm : findSplit;
    import std.exception : enforce;
    import std.string : strip;

    auto split = findSplit(str, " = ");
    enforce(split[0].length && split[2].length,
        new RecipeReadException(filename, lineNum, "Error reading binding: "~str)
    );
    return [ split[0].strip(), split[2].strip() ];
}
