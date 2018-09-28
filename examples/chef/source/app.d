import dbuild.chef.lua;
import dbuild.chef;
import dbuild.cook;

import std.stdio;

void main()
{
    auto lua = new LuaInterface;
    auto proj = lua.runFile("chef.lua");
    auto chef = new Chef(proj);
    chef.setDirs("build", "install");
    auto recipe = chef.buildRecipe();
    cookRecipe(recipe);
}
