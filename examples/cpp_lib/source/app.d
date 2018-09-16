import dbuild.cook;

int main(string[] args)
{
    auto recipe = Recipe (
        [
            Rule("cc", "gcc -MMD -MF$out.d -c -o $out $cflags $in")
                .withDeps(Deps.gcc)
                .withDepfile("$out.d")
                .withDescription("compiling $in"),

            Rule( "ar", "ar rcs $out $in")
                .withDescription("creating $out"),

            Rule("shared_ld", "gcc -shared -o $out $lflags $in")
                .withDescription("linking $out"),

            Rule( "exe_ld", "gcc -o $out $lflags $in")
                .withDescription("linking $out"),

            Rule("d_obj", "dmd -c -of$out $dflags $in")
                .withDescription("compiling $in"),

            Rule("d_exe", "dmd -of$out $lflags $in")
                .withDescription("linking $out"),
        ],

        [
            Build("cc", [ "c_cpp/source.cpp" ], "objs/source.o"),

            Build("cc", [ "c_cpp/c_source.cpp" ], "objs/c_source.o"),

            Build("cc", [ "c_cpp/source.cpp" ], "objs/source_PIC.o")
                .withBinding("cflags", "-fPIC"),

            Build("cc", [ "c_cpp/c_source.cpp" ], "objs/c_source_PIC.o")
                .withBinding("cflags", "-fPIC"),

            Build("cc", [ "c_cpp/main.cpp" ], "objs/main.o"),

            Build("ar", [ "objs/source.o", "objs/c_source.o" ], "lib/lib.a"),

            Build("shared_ld", [ "objs/source_PIC.o", "objs/c_source_PIC.o" ], "lib/liblib.so")
                .withBinding("lflags", "-lstdc++"),

            Build("exe_ld", [ "objs/main.o", "lib/lib.a" ], "bin/lib")
                .withBinding("lflags", "-lstdc++ -lm"),

            Build("d_obj", [ "d/lib.d" ], "objs/d_lib.o"),

            Build("d_obj", [ "d/app.d" ], "objs/d_app.o")
                .withBinding("dflags", "-Id"),

            Build("ar", [ "objs/d_lib.o" ], "lib/d_lib.a"),

            Build("d_exe", [ "objs/d_app.o", "lib/d_lib.a" ], "bin/lib-d")
                .withImplicitInputs(["lib/liblib.so"])
                .withBinding("lflags", "-L-Llib -L-llib")
        ]
    )
        .withBinding("cflags", "-O3")
        .withBinding("dflags", "-release");

    if (args.length > 1 && args[1] == "clean") {
        cleanRecipe(recipe);
    }
    else {
        try {
            cookRecipe(recipe);
        }
        catch (Exception ex) {
            import std.stdio : stderr;
            stderr.writeln("build failed:\n", ex.msg);
            return 1;
        }
    }
    return 0;
}
