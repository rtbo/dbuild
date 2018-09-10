import dbuild.cook;

void main()
{
    auto recipe = Recipe (
        [
            Rule("cc", "gcc -MMD -MF- -c -o $out $cflags $in")
                .withDeps(Deps.gcc)
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

            Build("exe_ld", [ "objs/source.o", "objs/c_source.o", "objs/main.o", "lib/lib.a" ], "bin/lib")
                .withBinding("lflags", "-lstdc++ -lm"),

            Build("d_obj", [ "d/lib.d" ], "objs/d_lib.o"),

            Build("d_obj", [ "d/app.d" ], "objs/d_app.o")
                .withBinding("dflags", "-Id"),

            Build("ar", [ "objs/d_lib.o" ], "lib/d_lib.a"),

            Build("d_exe", [ "objs/d_app.o", "lib/d_lib.a" ], "bin/lib-d")
                .withImplicitInputs(["lib/liblib.so"])
                .withBinding("lflags", "-L-Llib -L-llib")
        ]
    );

    cookRecipe(recipe);
}
