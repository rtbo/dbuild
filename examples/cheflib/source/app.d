import dbuild.chef;
import dbuild.cook;

void main(string[] args)
{
    auto proj = new Project("ChefExample");

    auto lib = new StaticLibrary("lib");
    auto dylib = new DynamicLibrary("dylib");
    auto exe = new Executable("exe");
    auto dLib = new StaticLibrary("d_lib");
    auto dExe = new Executable("d_exe");

    auto cpp = new CppGen();
    auto d = new DGen();
    d.importPaths = [ "../src/d" ];

    lib.inputs = [ "../src/c_cpp/source.cpp", "../src/c_cpp/c_source.cpp" ];
    lib.generators = [ cpp ];

    dylib.inputs = [ "../src/c_cpp/source.cpp", "../src/c_cpp/c_source.cpp" ];
    dylib.generators = [ cpp ];

    exe.inputs = [ "../src/c_cpp/main.cpp" ];
    exe.generators = [ cpp ];
    exe.dependencies = ["lib"];

    dLib.inputs = [ "../src/d/lib.d" ];
    dLib.generators = [ d ];

    dExe.inputs = [ "../src/d/app.d" ];
    dExe.generators = [ d ];
    dExe.dependencies = ["d_lib", "dylib"];

    proj.products = [ lib, dylib, exe, dLib, dExe ];

    auto chef = new Chef(proj);
    chef.setDirs("build", "install");
    auto recipe = chef.buildRecipe();
    cookRecipe(recipe);
}
