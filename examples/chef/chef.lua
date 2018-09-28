
chef = Project {

    name = "ChefExample",

    products = {
        StaticLibrary {
            name = "lib",
            source = {
                "../src/c_cpp/source.cpp", "../src/c_cpp/c_source.cpp"
            },
            generators = { CppGen() },
        },
        DynamicLibrary {
            name = "dylib",
            source = {
                "../src/c_cpp/source.cpp", "../src/c_cpp/c_source.cpp"
            },
            generators = { CppGen() },
        },
        Executable {
            name = "exe",
            source = { "../src/c_cpp/main.cpp" },
            generators = CppGen(),
            dependencies = "lib",
        },
        StaticLibrary {
            name = "d_lib",
            source = { "../src/d/lib.d" },
            generators = DGen(),
        },
        Executable {
            name = "d_exe",
            source = { "../src/d/app.d" },
            generators = DGen {
                importPaths = "../src/d"
            },
            dependencies = { "d_lib", "dylib" },
        }
    }
}
