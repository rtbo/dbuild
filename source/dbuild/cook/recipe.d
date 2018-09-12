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
