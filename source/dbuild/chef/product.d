module dbuild.chef.product;

import dbuild.chef;
import dbuild.chef.gen;
import dbuild.chef.project;
import dbuild.cook.recipe;

/// A clause interpreted at install time
struct InstallClause
{
    /// The input files to be installed. Can be glob matched with *.
    /// Can have special values:
    ///   - $artifact: the product generated artifact (should appear max once per clause)
    string[] inputs;
    /// The destination directory (relative to install prefix)
    string destDir = ".";
    /// Input prefix to be removed in the destination directory
    string removedPrefix = null;
}

/// A Product takes a set of input file to produce
/// an artifact with some generators.
class Product
{
    package Project _project;
    private string _name;
    private string[] _inputs;
    private InstallClause[] _installClauses;
    private string[] _dependencies;
    private Generator[] _generators;
    private Generator[] _exportedGenerators;

    this (in string name)
    {
        _name = name;
    }

    @property Project project()
    {
        return _project;
    }

    @property string name()
    {
        return _name;
    }

    @property string[] inputs()
    {
        return _inputs;
    }
    @property void inputs(string[] inputs)
    {
        _inputs = inputs;
    }

    Rule[] issueCookRules(Chef chef)
    {
        Rule[] rules;
        foreach (g; _generators) {
            rules ~= g.issueCookRules(chef, this);
        }
        return rules;
    }
    Build[] issueCookBuilds(Chef chef)
    {
        Build[] builds;
        foreach (g; _generators) {
            builds ~= g.issueCookBuilds(chef, this);
        }
        return builds;
    }

    @property string[] dependencies()
    {
        return _dependencies;
    }

    @property void dependencies(string[] dependencies)
    {
        _dependencies = dependencies;
    }

    @property Product[] dependenciesProd()
    {
        import std.algorithm : map;
        import std.array : array;
        import std.exception : enforce;

        return _dependencies.map!(d => enforce(project.product(d))).array;
    }

    @property Generator[] generators()
    {
        return _generators;
    }
    @property void generators(Generator[] generators)
    {
        _generators = generators;
    }

    @property Generator[] exportedGenerators()
    {
        return _exportedGenerators;
    }
    @property void exportedGenerators(Generator[] exportedGenerators)
    {
        _exportedGenerators = exportedGenerators;
    }


    string[] artifactDeps(Chef chef, string[] visited=null)
    {
        import std.algorithm : canFind;

        if (visited.canFind(name)) return [];
        visited ~= name;

        string[] deps;

        foreach (d; dependenciesProd) {
            deps ~= d.artifactDeps(chef, visited);
            foreach (g; d.generators) {
                deps ~= g.artifacts(chef, d);
            }
        }

        return deps;
    }
}

enum Linkage
{
    executable,
    dynamicLibrary,
    staticLibrary,
}

/// Product whose inputs are compiled into object files and linked together
/// into an artifact containing native machine code
class NativeCode : Product
{
    private string _targetName;
    private Linkage _linkage;

    this (in string name, in Linkage linkage)
    {
        super(name);
        _linkage = linkage;
        _targetName = name;
    }

    @property Linkage linkage()
    {
        return _linkage;
    }

    @property string targetName()
    {
        return _targetName;
    }
    @property void targetName(in string targetName)
    {
        _targetName = targetName;
    }

    @property NativeCodeGenerator linkerGen()
    {
        import std.algorithm : map;

        foreach (g; _generators.map!(g => cast(NativeCodeGenerator)g)) {
            if (g && g.linker) return g;
        }
        return null;
    }

    @property string artifactName()
    {
        import std.exception : enforce;

        return enforce(linkerGen).artifactName(this);
    }

    string artifactPath(Chef chef)
    {
        import std.path : buildPath;

        return buildPath(chef.buildDir, name, artifactName);
    }
}

class Executable : NativeCode
{
    this (in string name)
    {
        super(name, Linkage.executable);
    }
}

class DynamicLibrary : NativeCode
{
    this (in string name)
    {
        super(name, Linkage.dynamicLibrary);
    }
}

class StaticLibrary : NativeCode
{
    this (in string name)
    {
        super(name, Linkage.staticLibrary);
    }
}
