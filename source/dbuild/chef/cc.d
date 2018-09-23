module dbuild.chef.cc;

import dbuild.chef;
import dbuild.chef.gen;
import dbuild.cook;

import std.range : ElementType, isOutputRange;
import std.traits : isSomeString;

enum Cc
{
    gnu,
    clang,
    //msvc,
}

enum Language
{
    c, cpp,
}

class CCompiler : Compiler
{
    private Cc _cc;
    private string _path;

    static CCompiler get(Cc cc)
    {
        import std.exception : enforce;

        static GccCompiler _gcc;
        static ClangCompiler _clang;

        if (cc == Cc.gnu) {
            if (!_gcc) _gcc = new GccCompiler(enforce(_gccPath, "gcc not found in PATH"));
            return _gcc;
        }
        if (cc == Cc.clang) {
            if (!_clang) _clang = new ClangCompiler(enforce(_clangPath, "clang not found in PATH"));
            return _clang;
        }

        throw new Exception("Could not find relevant C/C++ compiler");
    }

    private this(Cc cc, string path)
    {
        _cc = cc;
        _path = path;
    }

    @property Cc cc()
    {
        return _cc;
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
            return "lib" ~ targetName ~ ".a";
        }
    }

    abstract string program(Language lang);

    string objectRuleName(Language lang)
    {
        import std.format : format;

        return format("%s_%s_obj", _cc, lang);
    }

    string linkRuleName(Language lang, Linkage linkage)
    {
        import std.format : format;

        return format("%s_%s_%s", _cc, lang, linkage);
    }

    Rule objectRule(Language lang)
    {
        import dbuild.cook : escapeString;
        import std.format : format;

        return Rule(
            objectRuleName(lang),
            format("%s -MMD -MF$out.deps -c -o $out $cflags $in", program(lang))
        )
            .withDeps(Deps.gcc)
            .withDepfile("$out.deps")
            .withDescription("Compiling $in");
    }

    Rule linkRule(Language lang, Linkage linkage)
    {
        import dbuild.cook : escapeString;
        import std.format : format;

        const rn = linkRuleName(lang, linkage);

        final switch (linkage)
        {
        case Linkage.executable:
            return Rule(rn, format(
                "%s -o $out $lflags $in", program(lang)
            )).withDescription("Linking $out");
        case Linkage.dynamicLibrary:
            return Rule(rn, format(
                "%s -shared -o $out $lflags $in", program(lang)
            )).withDescription("Linking $out");
        case Linkage.staticLibrary:
            return Rule(rn, "ar rcs $out $in")
                    .withDescription("Creating $out");
        }
    }

}

final class GccCompiler : CCompiler
{
    private this (string path)
    {
        super(Cc.gnu, path);
    }

    override string program(Language lang)
    {
        final switch (lang) {
        case Language.c: return "gcc";
        case Language.cpp: return "g++";
        }
    }
}

final class ClangCompiler : CCompiler
{
    private this (string path)
    {
        super(Cc.clang, path);
    }

    override string program(Language lang)
    {
        final switch (lang) {
        case Language.c: return "clang";
        case Language.cpp: return "clang++";
        }
    }
}

/// Discover which compilers are installed on the system
const(Cc)[] installedCcs()
{
    import dbuild.util : searchExecutable;

    static bool discovered;
    static Cc[] ccs;

    if (discovered) return ccs;

    discovered = true;

    // version(Windows) {
    //     import dbuild.msvc : detectMsvcInstalls;

    //     // if invoked from Visual Studio prompt, use that cl.exe, otherwise
    //     // check what is installed on system
    //     _clPath = searchExecutable("cl");
    //     _msvcInstalls = detectMsvcInstalls();

    //     if (_clPath.length || _msvcInstalls.length) ccs ~= Cc.msvc;
    // }

    _gccPath = searchExecutable("gcc");
    _clangPath = searchExecutable("clang");

    version (OSX) {
        if (_clangPath.length) ccs ~= Cc.clang;
        if (_gccPath.length) ccs ~= Cc.gnu;
    }
    else {
        if (_gccPath.length) ccs ~= Cc.gnu;
        if (_clangPath.length) ccs ~= Cc.clang;
    }

    return ccs;
}

version(Windows)
{
    /// Get the different installations of MSVC, sorted from highest version
    /// to lowest
    const(MsvcInstall)[] msvcInstalls()
    {
        installedCc();
        return _msvcInstalls;
    }
}


enum Optimizations
{
    none,
    speed,
    space,
    speedSpace,
}

enum StdC
{
    unknown,
    ansi,
    c89=ansi,
    c99,
    c11,
    c17,
}

enum StdCpp
{
    unknown,
    cpp98,
    cpp11,
    cpp14,
    cpp17,
}

string archFlag(in Cc cc, in Arch arch)
{
    import std.format : format;

    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        return format("-m%s", arch.pointerSize);
    // case Cc.msvc:
    //     throw new Exception("msvc arch is specified upfront with vcvarsall.bat");
    }
}

string picFlag(in Cc cc)
{
    import std.format : format;

    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        return "-fPIC";
    // case Cc.msvc:
    //     throw new Exception("msvc arch is specified upfront with vcvarsall.bat");
    }
}

string optimizationsFlag(in Cc cc, in Optimizations opt)
{
    import std.format : format;

    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        final switch (opt)
        {
        case Optimizations.none:
            return "";
        case Optimizations.speed:
            return "-O3";
        case Optimizations.space:
            return "-Os";
        case Optimizations.speedSpace:
            return "-O2";
        }
    // case Cc.msvc:
    //     final switch (opt)
    //     {
    //     case Optimizations.none:
    //         return "/Od";
    //     case Optimizations.speed:
    //         return "/O2";
    //     case Optimizations.space:
    //         return "/O1";
    //     case Optimizations.speedSpace:
    //         return "/O2";
    //     }
    //     break;
    }
}

string debugSymbolFlag(in Cc cc)
{
    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        return "-g";
    // case Cc.msvc:
    //     return "/Zi";
    }
}

string stdCFlag(in Cc cc, in StdC stdc)
{
    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        final switch (stdc) {
        case StdC.unknown:  return null;
        case StdC.ansi:     return "-ansi";
        //case StdC.c89:      return "-std=c89";
        case StdC.c99:      return "-std=c99";
        case StdC.c11:      return "-std=c11";
        case StdC.c17:      return "-std=c17";
        }
    // case Cc.msvc:
    //     return "/Zi";
    }
}

string stdCppFlag(in Cc cc, in StdCpp stdcpp)
{
    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        final switch (stdcpp) {
        case StdCpp.unknown:    return null;
        case StdCpp.cpp98:      return "-std=c++98";
        case StdCpp.cpp11:      return "-std=c++11";
        case StdCpp.cpp14:      return "-std=c++14";
        case StdCpp.cpp17:      return "-std=c++17";
        }
    // case Cc.msvc:
    //     return "/Zi";
    }
}

string defineFlag(in Cc cc, in string define, in string value)
{
    import std.format : format;

    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        if (value.length) {
            return format("-D%s=%s", define, value);
        }
        else {
            return format("-D%s", define);
        }
    }
}

string includeFlag(in Cc cc, in string include)
{
    import std.format : format;

    final switch (cc) {
    case Cc.gnu:
    case Cc.clang:
        return format("-I%s", include);
    }
}

private:

// version(Windows)
// {
//     import dbuild.msvc : MsvcInstall;

//     MsvcInstall[] _msvcInstalls;
//     string _clPath;
// }
string _gccPath;
string _clangPath;
