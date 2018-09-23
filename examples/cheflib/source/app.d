import dbuild.chef;
import dbuild.cook;

void main(string[] args)
{
    auto proj = new Project("ChefExample");

    auto lib = new StaticLibrary(proj, "lib");
    auto dylib = new DynamicLibrary(proj, "dylib");
    auto exe = new Executable(proj, "exe");
    auto dLib = new StaticLibrary(proj, "d_lib");
    auto dExe = new Executable(proj, "d_exe");

    auto cpp = new CppGen();
    auto d = new DGen();
    d.importPaths = [ "d" ];

    lib.inputs = [ "c_cpp/source.cpp", "c_cpp/c_source.cpp" ];
    lib.generators = [ cpp ];

    dylib.inputs = [ "c_cpp/source.cpp", "c_cpp/c_source.cpp" ];
    dylib.generators = [ cpp ];

    exe.inputs = [ "c_cpp/main.cpp" ];
    exe.generators = [ cpp ];
    exe.dependencies = ["lib"];

    dLib.inputs = [ "d/lib.d" ];
    dLib.generators = [ d ];

    dExe.inputs = [ "d/app.d" ];
    dExe.generators = [ d ];
    dExe.dependencies = ["d_lib", "dylib"];

    proj.products = [ lib, dylib, exe, dLib, dExe ];

    auto chef = new Chef(proj);
    chef.setDirs("build", "install");
    auto recipe = chef.buildRecipe();
    cookRecipe(recipe);
}
