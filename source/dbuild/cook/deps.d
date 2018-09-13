module dbuild.cook.deps;

import std.range.primitives;
import std.traits : isSomeString;

/// Read the depfile containing a single makefile rule and return the dependencies.
/// If target is provided, it is enforced whether the target in the depfile
/// is identical to target.
string[] readMkDepFile(in string depfile, in string target=null)
{
    import std.stdio : File;

    auto f = File(depfile, "r");
    return readMkDeps(f.byLineCopy, target);
}

/// Read the deplines containing a single makefile rule and return the dependencies.
/// If target is provided, it is enforced whether the target in the lines
/// is identical to target.
string[] readMkDeps(R)(R deplines, in string target=null)
if (isInputRange!R && isSomeString!(ElementType!R))
{
    import std.algorithm : findSplit;
    import std.ascii : isWhite;
    import std.exception : enforce;
    import std.range : enumerate;
    import std.string : strip;

    string[] deps;

    foreach (i, line; enumerate(deplines))
    {
        if (i == 0) {
            const split = findSplit(line, ":");
            string deptarget = split[0];
            line = split[2];
            enforce(!target || target == deptarget, deptarget ~ " does not fit with expected " ~ target);
        }

        line = line.strip();

        string dep;
        bool escape;
        foreach (char c; line) {
            if (c == '\\' && !escape) {
                escape = true;
            }
            else if (escape) {
                dep ~= c;
                escape = false;
            }
            else if (c.isWhite) {
                if (dep.length) {
                    deps ~= dep;
                    dep = null;
                }
            }
            else {
                dep ~= c;
            }
        }
        if (dep.length) deps ~= dep;
    }
    return deps;
}

unittest
{
    import std.exception : assertNotThrown, assertThrown;

    auto lines = [
        `objs/c_source.o: c_cpp/c\ source.cpp /usr/include/stdc-predef.h \`,
        ` c_cpp/header.h c_cpp/header.hpp`
    ];
    const res = assertNotThrown!Exception(readMkDeps(lines, "objs/c_source.o"));
    assert(res == [ "c_cpp/c source.cpp", "/usr/include/stdc-predef.h",
        "c_cpp/header.h", "c_cpp/header.hpp" ]);
    assertThrown!(Exception)(readMkDeps(lines, "othertarget"));
}
