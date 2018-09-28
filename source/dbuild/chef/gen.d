module dbuild.chef.gen;

import dbuild.chef;
import dbuild.chef.product;
import dbuild.cook.recipe;


abstract class Generator
{
    private string _name;

    this (in string name)
    {
        _name = name;
    }

    final @property string name()
    {
        return _name;
    }

    abstract bool matches(in string name);
    abstract Rule[] issueCookRules(Chef chef, Product product);
    abstract Build[] issueCookBuilds(Chef chef, Product product);
    abstract string[] artifacts(Chef chef, Product product);

    final Generator[] dependenciesExports(Product product, string[] collectedProds=null)
    {
        import std.algorithm : canFind;
        import std.exception : enforce;

        if (collectedProds.canFind(product.name)) return null;
        collectedProds ~= product.name;

        Generator[] gens;

        foreach (d; product.dependencies) {
            auto prod = enforce(product.project.product(d), d~" not found in project");
            gens ~= dependenciesExports(prod, collectedProds);
            foreach (g; prod.exportedGenerators) {
                if (g.name == name) gens ~= g;
            }
        }

        return gens;
    }
}


interface Compiler
{
    string artifactName(in string targetName, in Linkage linkage);
}

abstract class NativeCodeGenerator : Generator
{
    private Compiler _compiler;
    private bool _linker;

    this(string name, Compiler compiler, bool linker)
    {
        super(name);
        _compiler = compiler;
        _linker = linker;
    }

    final @property Compiler compiler()
    {
        return _compiler;
    }

    final @property bool linker()
    {
        return _linker;
    }

    final override string[] artifacts(Chef chef, Product product)
    {
        import std.exception : enforce;

        if (_linker) {
            auto prod = enforce(
                cast(NativeCode)product,
                "NativeCodeGen must be used with NativeCode products"
            );
            return [ prod.artifactPath(chef) ];
        }
        else {
            return null;
        }
    }

    final protected NativeCode nativeCode(Product product)
    {
        import std.exception : enforce;

        return enforce(
            cast(NativeCode)product,
            "NativeCodeGen must be used with NativeCode products"
        );
    }

    string artifactName(Product product)
    {
        auto prod = nativeCode(product);
        return _compiler.artifactName(prod.name, prod.linkage);
    }

    abstract override bool matches(in string name);

    abstract override Rule[] issueCookRules(Chef chef, Product product);
    abstract override Build[] issueCookBuilds(Chef chef, Product product);
}

private bool nameIsLib(string name)
{
    import std.algorithm : endsWith;

    version(Windows) {
        if (name.endsWith(".dll")) return true;
        if (name.endsWith(".lib")) return true;
    }
    version (OSX) {
        if (name.endsWith(".dylib")) return true;
    }
    version (Posix) {
        if (name.endsWith(".so")) return true;
    }
    if (name.endsWith(".a")) return true;
    return false;
}

final class CppGen : NativeCodeGenerator
{
    import dbuild.chef.cc;

    enum cpp = "cpp";

    private string[string] _defines;
    private string[] _includePaths;
    private string[] _cflags;
    private string[] _lflags;
    private StdC _stdc;
    private StdCpp _stdcpp;
    private Cc _cc;

    private static bool nameIsCpp(in string name)
    {
        import std.algorithm : endsWith;

        return name.endsWith(".cpp") || name.endsWith(".cc") || name.endsWith(".cxx");
    }

    private static bool nameIsC(in string name)
    {
        import std.algorithm : endsWith;

        return name.endsWith(".c");
    }

    this(bool linker=true)
    {
        import std.exception : enforce;

        const ccs = installedCcs();
        enforce(ccs.length, "No suitable C/C++ compiler found");
        _cc = ccs[0];
        auto compiler = CCompiler.get(ccs[0]);
        super(cpp, compiler, linker);
    }

    @property Cc cc()
    {
        return _cc;
    }

    @property CCompiler ccompiler()
    {
        return cast(CCompiler)_compiler;
    }

    @property string[] includePaths()
    {
        return _includePaths;
    }
    @property void includePaths(string[] includePaths)
    {
        _includePaths = includePaths;
    }

    @property string[string] defines()
    {
        return _defines;
    }
    @property void defines(string[string] defines)
    {
        _defines = defines;
    }

    @property string[] cflags()
    {
        return _cflags;
    }
    @property void cflags(string[] cflags)
    {
        _cflags = cflags;
    }

    @property string[] lflags()
    {
        return _lflags;
    }
    @property void lflags(string[] lflags)
    {
        _lflags = lflags;
    }

    override bool matches(in string name)
    {
        return nameIsC(name) || nameIsCpp(name);
    }

    override Rule[] issueCookRules(Chef chef, Product product)
    {
        bool hasC, hasCpp;
        foreach (i; product.inputs) {
            if (nameIsC(i)) hasC = true;
            else if (nameIsCpp(i)) hasCpp = true;
            if (hasC && hasCpp) break;
        }

        Rule[] rules;
        if (hasC) {
            rules ~= ccompiler.objectRule(Language.c);
        }
        if (hasCpp) {
            rules ~= ccompiler.objectRule(Language.cpp);
        }
        if (_linker) {
            const lang = hasCpp ? Language.cpp : Language.c;
            rules ~= ccompiler.linkRule(lang, nativeCode(product).linkage);
        }
        return rules;
    }

    override Build[] issueCookBuilds(Chef chef, Product product)
    {
        import std.algorithm : endsWith, filter, map, sort, uniq;
        import std.array : array, join;
        import std.exception : enforce;
        import std.path : baseName, buildPath;
        import dbuild.cook : escapeString;

        auto prod = nativeCode(product);

        auto deps = dependenciesExports(product).map!(g => cast(CppGen)g).array;

        const stdc = collectStdC(deps);
        const stdcpp = collectStdCpp(deps);
        auto cflags = collectCFlags(deps);

        if (chef.buildType == BuildType.debug_)
            cflags ~= debugSymbolFlag(_cc);
        else
            cflags ~= optimizationsFlag(_cc, Optimizations.speed);

        cflags ~= archFlag(_cc, chef.arch);

        foreach (d, v; collectDefines(deps)) {
            cflags ~= defineFlag(_cc, d, v);
        }
        foreach (i; collectIncludes(deps)) {
            cflags ~= includeFlag(_cc, i);
        }
        if (prod.linkage == Linkage.dynamicLibrary) {
            cflags ~= picFlag(_cc);
        }

        cflags.sort();
        const flagStr = cflags
                .uniq()
                .filter!(s => s.length>0)
                .map!escapeString.join(" ");
        const cflagStr = stdc == StdC.unknown ? flagStr : stdCFlag(_cc, stdc) ~ " " ~ flagStr;
        const cppflagStr = stdcpp == StdCpp.unknown ? flagStr : stdCppFlag(_cc, stdcpp) ~ " " ~ flagStr;

        Build[] result;
        string[] objects;

        const buildDir = chef.buildDir.buildPath(product.name);
        bool hasCpp;

        foreach (input; product.inputs.filter!(i => matches(i))) {

            const obj = buildPath(buildDir, baseName(input)~".o");
            objects ~= obj;

            const lang = nameIsC(input) ? Language.c : Language.cpp;
            const flags = lang == Language.cpp ? cppflagStr : cflagStr;
            if (lang == Language.cpp) hasCpp = true;

            result ~= Build(ccompiler.objectRuleName(lang), [ input ], obj)
                .withBinding("cflags", flags);
        }

        if (_linker) {
            string[] libDeps;
            string[] implicitInputs;
            foreach (ad; product.artifactDeps(chef)) {
                if (nameIsLib(ad)) {
                    libDeps ~= ad;
                }
                else {
                    implicitInputs ~= ad;
                }
            }

            const lflags = collectLFlags(deps).map!escapeString.join(" ");
            const lang = hasCpp ? Language.cpp : Language.c;

            result ~= Build(
                ccompiler.linkRuleName(lang, prod.linkage),
                objects ~ libDeps, prod.artifactPath(chef)
            )
                .withBinding("lflags", lflags)
                .withImplicitInputs(implicitInputs);
        }

        return result;
    }


    private StdC collectStdC(CppGen[] dependencies)
    {
        StdC maxStdC;
        foreach (g; dependencies) {
            if (g._stdc > maxStdC) maxStdC = g._stdc;
        }
        if (_stdc > maxStdC) maxStdC = _stdc;
        return maxStdC;
    }

    private StdCpp collectStdCpp(CppGen[] dependencies)
    {
        StdCpp maxStdCpp;
        foreach (g; dependencies) {
            if (g._stdcpp > maxStdCpp) maxStdCpp = g._stdcpp;
        }
        if (_stdcpp > maxStdCpp) maxStdCpp = _stdcpp;
        return maxStdCpp;
    }

    private string[] collectCFlags(CppGen[] dependencies)
    {
        string[] cflags;
        foreach (g; dependencies) {
            cflags ~= g._cflags;
        }
        return cflags ~ _cflags;
    }

    private string[string] collectDefines(CppGen[] dependencies)
    {
        import std.format : format;

        string[string] defines;
        foreach (g; dependencies) {
            foreach (d, v; g.defines) {
                defines[d] = v;
            }
        }
        foreach (d, v; _defines) {
            defines[d] = v;
        }
        return defines;
    }

    private string[] collectIncludes(CppGen[] dependencies)
    {
        string[] includes;
        foreach (g; dependencies) {
            includes ~= g.includePaths;
        }
        return includes ~ _includePaths;
    }

    private string[] collectLFlags(CppGen[] dependencies)
    {
        string[] lflags;
        foreach (g; dependencies) {
            lflags ~= g._lflags;
        }
        return lflags ~ _lflags;
    }
}

class DGen : NativeCodeGenerator
{
    import dbuild.chef.dc;

    private string[] _versionIdents;
    private string[] _debugIdents;
    private string[] _importPaths;
    private string[] _dflags;
    private string[] _lflags;
    private Dc _dc;

    enum d = "d";

    this(bool linker=true)
    {
        import std.exception : enforce;

        const dcs = installedDcs();
        enforce(dcs.length, "No suitable C/C++ compiler found");
        _dc = dcs[0];
        auto compiler = DCompiler.get(dcs[0]);
        super(d, compiler, linker);
    }

    @property string[] debugIdents()
    {
        return _debugIdents;
    }
    @property void debugIdents(string[] idents)
    {
        _debugIdents = idents;
    }

    @property string[] versionIdents()
    {
        return _versionIdents;
    }
    @property void versionIdents(string[] idents)
    {
        _versionIdents = idents;
    }

    @property string[] importPaths()
    {
        return _importPaths;
    }
    @property void importPaths(string[] importPaths)
    {
        _importPaths = importPaths;
    }

    @property string[] dflags()
    {
        return _dflags;
    }
    @property void dflags(string[] dflags)
    {
        _dflags = dflags;
    }

    @property string[] lflags()
    {
        return _lflags;
    }
    @property void lflags(string[] lflags)
    {
        _lflags = lflags;
    }

    @property DCompiler dcompiler()
    {
        return cast(DCompiler)_compiler;
    }

    override string artifactName(Product product)
    {
        import std.exception : enforce;

        auto prod = enforce(
            cast(NativeCode)product,
            "NativeCodeGen must be used with NativeCode products"
        );
        return dcompiler.artifactName(prod.name, prod.linkage);
    }


    override bool matches(in string name)
    {
        import std.algorithm : endsWith;

        return name.endsWith(".d");
    }

    override Rule[] issueCookRules(Chef chef, Product product)
    {
        if (_linker) {
            return [
                dcompiler.objectRule(),
                dcompiler.linkRule(nativeCode(product).linkage)
            ];
        }
        else {
            return [ dcompiler.objectRule() ];
        }
    }

    override Build[] issueCookBuilds(Chef chef, Product product)
    {
        import std.algorithm : filter, map, sort, uniq;
        import std.array : array, join;
        import std.exception : enforce;
        import std.path : baseName, buildPath;
        import dbuild.cook : escapeString;

        auto prod = enforce(
            cast(NativeCode)product,
            "NativeCodeGenerator must be used with NativeCode products"
        );

        auto deps = dependenciesExports(product).map!(g => cast(DGen)g).array;
        auto dflags = collectDFlags(deps);

        dflags ~= buildTypeFlags(_dc, chef.buildType);
        dflags ~= archFlag(_dc, chef.arch);

        foreach (f; collectImportPaths(deps).map!(i => importPathFlag(_dc, i))) {
            dflags ~= f;
        }
        foreach (f; collectDebugIdents(deps).map!(i => debugIdentFlag(_dc, i))) {
            dflags ~= f;
        }
        foreach (f; collectVersionIdents(deps).map!(i => versionIdentFlag(_dc, i))) {
            dflags ~= f;
        }

        dflags.sort();
        const flagStr = dflags
                .uniq()
                .filter!(s => s.length > 0)
                .map!escapeString.join(" ");

        Build[] result;
        string[] objects;

        const buildDir = chef.buildDir.buildPath(product.name);
        const objRn = dcompiler.objectRuleName();

        foreach (input; product.inputs.filter!(i => matches(i))) {

            const obj = buildPath(buildDir, baseName(input)~".o");
            objects ~= obj;

            result ~= Build(objRn, [ input ], obj)
                .withBinding("dflags", flagStr);
        }

        if (_linker) {
            string[] libDeps;
            string[] implicitInputs;
            foreach (ad; product.artifactDeps(chef)) {
                if (nameIsLib(ad)) {
                    libDeps ~= ad;
                }
                else {
                    implicitInputs ~= ad;
                }
            }

            const lflags = collectLFlags(deps).map!escapeString.join(" ");

            result ~= Build(
                dcompiler.linkRuleName(prod.linkage),
                objects ~ libDeps, prod.artifactPath(chef)
            )
                .withBinding("dlflags", lflags)
                .withImplicitInputs(implicitInputs);
        }

        return result;
    }

    private string[] collectDFlags(DGen[] dependencies)
    {
        string[] dflags;
        foreach (g; dependencies) {
            dflags ~= g._dflags;
        }
        return dflags ~ _dflags;
    }

    private string[] collectImportPaths(DGen[] dependencies)
    {
        string[] paths;
        foreach (g; dependencies) {
            paths ~= g.importPaths;
        }
        return paths ~ _importPaths;
    }

    private string[] collectVersionIdents(DGen[] dependencies)
    {
        string[] idents;
        foreach (g; dependencies) {
            idents ~= g.versionIdents;
        }
        return idents ~ _versionIdents;
    }

    private string[] collectDebugIdents(DGen[] dependencies)
    {
        string[] idents;
        foreach (g; dependencies) {
            idents ~= g.debugIdents;
        }
        return idents ~ _debugIdents;
    }

    private string[] collectLFlags(DGen[] dependencies)
    {
        string[] lflags;
        foreach (g; dependencies) {
            lflags ~= g._lflags;
        }
        return lflags ~ _lflags;
    }
}
