module dbuild.chef.dc;

import dbuild.chef;
import dbuild.chef.gen;
import dbuild.cook;

enum Dc {
    dmd,
    ldc,
    gdc,
}

class DCompiler : Compiler
{
    private Dc _dc;
    private string _path;

    static DCompiler get(Dc dc)
    {
        import std.exception : enforce;

        static DmdCompiler _dmd;
        static LdcCompiler _ldc;
        static GdcCompiler _gdc;

        if (dc == Dc.dmd) {
            if (!_dmd) _dmd = new DmdCompiler(enforce(_dmdPath, "dmd not found in PATH"));
            return _dmd;
        }
        if (dc == Dc.ldc) {
            if (!_ldc) _ldc = new LdcCompiler(enforce(_ldcPath, "ldc not found in PATH"));
            return _ldc;
        }
        if (dc == Dc.gdc) {
            if (!_gdc) _gdc = new GdcCompiler(enforce(_gdcPath, "gdc not found in PATH"));
            return _gdc;
        }

        throw new Exception("Could not find relevant D compiler");
    }

    private this(Dc dc, string path)
    {
        _dc = dc;
        _path = path;
    }

    @property Dc dc()
    {
        return _dc;
    }

    @property string path()
    {
        return _path;
    }

    override string artifactName(in string targetName, in Linkage linkage)
    {
        final switch (linkage)
        {
        case Linkage.executable:
            version(Windows) {
                return targetName ~ ".exe";
            }
            else {
                return targetName;
            }
        case Linkage.dynamicLibrary:
            version(Windows) {
                return targetName ~ ".dll";
            }
            else version(OSX) {
                return "lib" ~ targetName ~ ".dylib";
            }
            else version(Posix) {
                return "lib" ~ targetName ~ ".so";
            }
            else {
                static assert(false, "unsupported platform");
            }
        case Linkage.staticLibrary:
            version (Windows) {
                return targetName ~ ".lib";
            }
            else {
                return "lib" ~ targetName ~ ".a";
            }
        }
    }

    string objectRuleName()
    {
        import std.format : format;

        return format("%s_obj", _dc);
    }

    string linkRuleName(Linkage linkage)
    {
        import std.format : format;

        return format("%s_%s", _dc, linkage);
    }

    Rule objectRule()
    {
        import dbuild.cook : escapeString;
        import std.format : format;

        return Rule(
            objectRuleName(),
            format("%s -c -of$out $dflags $in", escapeString(path))
        )
            .withDescription("Compiling $inName");
    }

    Rule linkRule(Linkage linkage)
    {
        import dbuild.cook : escapeString;
        import std.format : format;

        const rn = linkRuleName(linkage);

        final switch (linkage)
        {
        case Linkage.executable:
            return Rule(rn, format(
                "%s -of$out $dlflags $in", escapeString(path)
            )).withDescription("Linking $outName");
        case Linkage.dynamicLibrary:
            return Rule(rn, format(
                "%s -shared -of$out $dlflags $in", escapeString(path)
            )).withDescription("Linking $outName");
        case Linkage.staticLibrary:
            return Rule(rn, "ar rcs $out $in").withDescription("Creating $outName");
        }
    }
}

final class DmdCompiler : DCompiler
{
    private this (string path)
    {
        super(Dc.dmd, path);
    }

}

final class LdcCompiler : DCompiler
{
    private this (string path)
    {
        super(Dc.dmd, path);
    }
}

final class GdcCompiler : DCompiler
{
    private this (string path)
    {
        super(Dc.gdc, path);
    }
}

string archFlag(in Dc dc, in Arch arch)
{
    import std.format : format;

    final switch (dc)
    {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        return format("-m%s", arch.pointerSize);
    }
}

string picFlag(in Dc dc)
{
    import std.format : format;

    final switch (dc) {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        return "-fPIC";
    }
}

string[] buildTypeFlags(in Dc dc, in BuildType buildType)
{
    final switch (dc)
    {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        if (buildType == BuildType.debug_) {
            return [ "-g", "-debug" ];
        }
        else {
            return [ "-release" ];
        }
    }
}

string importPathFlag(in Dc dc, in string importPath)
{
    final switch (dc)
    {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        return "-I"~importPath;
    }
}

string versionIdentFlag(in Dc dc, in string ident)
{
    final switch (dc)
    {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        return "-version="~ident;
    }
}

string debugIdentFlag(in Dc dc, in string ident)
{
    final switch (dc)
    {
    case Dc.dmd:
    case Dc.ldc:
    case Dc.gdc:
        return "-debug="~ident;
    }
}

/// Discover which compilers are installed on the system
const(Dc)[] installedDcs()
{
    import dbuild.util : searchExecutable;

    static bool discovered;
    static Dc[] dcs;

    if (discovered) return dcs;

    discovered = true;

    _dmdPath = searchExecutable("dmd");
    _ldcPath = searchExecutable("ldc2");
    _gdcPath = searchExecutable("gdc");

    if (_dmdPath.length) dcs ~= Dc.dmd;
    if (_ldcPath.length) dcs ~= Dc.ldc;
    if (_gdcPath.length) dcs ~= Dc.gdc;

    return dcs;
}

private:

string _dmdPath;
string _ldcPath;
string _gdcPath;
