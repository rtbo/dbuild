module dbuild.chef.lua;

import dbuild.chef.project;
import derelict.lua.lua;

import std.exception : enforce;

class LuaInterface
{
    private lua_State* _L;

    this()
    {
        DerelictLua.load();
        _L = luaL_newstate();
        luaL_openlibs(_L);

        luaL_newmetatable(_L, "chef.Generator");
        luaL_newmetatable(_L, "chef.Product");
        luaL_newmetatable(_L, "chef.Project");

        registerFunc("CppGen", &dbuild_lua_CppGen);
        registerFunc("DGen", &dbuild_lua_DGen);
        registerFunc("StaticLibrary", &dbuild_lua_StaticLibrary);
        registerFunc("DynamicLibrary", &dbuild_lua_DynamicLibrary);
        registerFunc("Executable", &dbuild_lua_Executable);
        registerFunc("Product", &dbuild_lua_Product);
        registerFunc("Project", &dbuild_lua_Project);
    }

    void close() {
        lua_close(_L);
        _L = null;
    }

    Project runFile(in string filename)
    {
        import std.string : toStringz, fromStringz;

        if (luaL_loadfile(_L, toStringz(filename)) || lua_pcall(_L, 0, 0, 0)) {
            throw new Exception ("cannot run Lua file: " ~ fromStringz(lua_tostring(_L, -1)).idup);
        }

        lua_getglobal(_L, "chef");
        const type = lua_type(_L, -1);
        enforce(type != LUA_TNIL, "Lua scripts are expected to set the chef variable");
        enforce(type == LUA_TLIGHTUSERDATA, "chef must be assigned to a Project or Product");

        auto loc = lua_touserdata(_L, -1);
        assert(loc);
        exposeToGC(loc);

        if (lua_getmetatable(_L, -1)) {
            luaL_getmetatable(_L, "chef.Project");
            if (lua_rawequal(_L, -1, -2)) {
                lua_pop(_L, 2);
                return cast(Project)loc;
            }
            lua_pop(_L, 1);
            luaL_getmetatable(_L, "chef.Product");
            if (lua_rawequal(_L, -1, -2)) {
                lua_pop(_L, 2);
                auto proj = new Project(null);
                proj.products = [ cast(Product)loc ];
                return proj;
            }
            lua_pop(_L, 1);
        }
        lua_pop(_L, 1);

        hideFromGC(loc);
        throw new Exception("chef must be assigned to a Project or Product");
    }

    private void registerFunc(const(char)* name, lua_CFunction func)
    {
        lua_pushcfunction(_L, func);
        lua_setglobal(_L, name);
    }
}

private:

class LuaPrivException : Exception
{
    import std.exception : basicExceptionCtors;

    mixin basicExceptionCtors;
}

alias luaEnforce = enforce!LuaPrivException;

/// disallow GC to collect location
void hideFromGC(void* location)
{
    import core.memory : GC;

    GC.addRoot(location);
    GC.setAttr(location, GC.BlkAttr.NO_MOVE);
}

/// allow GC to collect location
void exposeToGC(void* location)
{
    import core.memory : GC;

    GC.removeRoot(location);
    GC.clrAttr(location, GC.BlkAttr.NO_MOVE);
}

/// boxes an alias f such as no exception can escape
auto box (alias f, Args...)(lua_State* L, Args args) nothrow
{
    alias Res = typeof(f(args));
    try {
        static if (is(Res == void)) {
            f(args);
        }
        else {
            return f(args);
        }
    }
    catch (LuaPrivException ex) {
        import std.string : toStringz;
        luaL_error( L, ex.msg.toStringz() );
        assert(false);
    }
    catch (Exception ex) {
        // in all cases we must return with luaL_error, as it longjmp until lua_pcall
        // (ANSI C implementation of stack unwinding)
        import std.string : toStringz;
        luaL_error(
            L, "%s: %s", ex.classinfo.name.toStringz(), ex.msg.toStringz()
        );
        assert(false);
    }
}


/// Get a string at index ind in the stack
string getString(lua_State* L, int ind)
{
    if (lua_isstring(L, ind)) {
        size_t len;
        const ptr = lua_tolstring(L, ind, &len);
        return ptr[ 0 .. len ].idup;
    }
    else {
        return null;
    }
}

/// Get a single string with key in table at ind
string getStringAt(lua_State* L, int tableInd, string key, bool mustHave=true)
in (tableInd > 0)
{
    import std.format : format;

    lua_pushlstring(L, key.ptr, key.length);
    const luaType = lua_gettable(L, tableInd);
    if (!mustHave && luaType == LUA_TNIL) return null;
    luaEnforce (
        luaType == LUA_TSTRING,
        format("was expecting string for key \"%s\"", key)
    );
    return getString(L, -1);
}

/// Get a list (sub-table) of strings at index key of a table at index tableInd
/// in the stack. If a single string is to be retrieved, it can be stored
/// directly as a string value instead of a table containing one string.
/// If the key is not defined, return null.
/// If is also allowed that the list of string is returned by an inline function
string[] getStringListAt(lua_State* L, int tableInd, string key)
in (tableInd > 0)
{
    lua_pushlstring(L, key.ptr, key.length);
    return getStringListFromTop(L, lua_gettable(L, tableInd), true);
}

/// Retrieve a list of string from top of Lua stack.
/// It can be a single string, an array of strings, nil (null is returned),
/// or (if allowFunc is true) a function evaluating to a single or array of strings.
string[] getStringListFromTop(lua_State* L, int typeAtTop, bool allowFunc=true)
{
    switch (typeAtTop) {
    case LUA_TSTRING:
        return [ getString(L, -1) ];
    case LUA_TTABLE:
        // top is a table containing (in principle) strings
        const tlen = luaL_len(L, -1);
        string[] res = new string[tlen];
        foreach (i; 0 .. tlen) {
            lua_rawgeti(L, -1, cast(int)(i+1));
            res[i] = getString(L, -1);
            lua_pop(L, 1);
        }
        return res;
    case LUA_TFUNCTION:
        if (!allowFunc) {
            throw new LuaPrivException("function not allowed");
        }
        lua_call(L, 0, 1);
        return getStringListFromTop(L, lua_type(L, -1), false);
    case LUA_TNIL:
        return null;
    default:
        throw new LuaPrivException("unexpected value");
    }
}

/// special case with C++ defines: a Lua table that can contain
/// intermixed values, and key-value pairs. In the former case we must push
/// the lua value as D key with a null D value. In the latter case, we add
/// the key-value pair in the D AA.
string[string] getDefinesTable(lua_State* L, int tabInd, string key)
{
    string[string] res;
    lua_pushlstring(L, key.ptr, key.length);
    switch (lua_gettable(L, tabInd)) {
    case LUA_TSTRING:
        res[getString(L, -1)] = null;
        break;
    case LUA_TTABLE:
        lua_pushnil(L);
        while (lua_next(L, -1) != 0) {
            if (lua_isstring(L, -2)) {
                res[getString(L, -2)] = getString(L, -1);
            }
            else {
                res[getString(L, -1)] = null;
            }
            lua_pop(L, 1);
        }
        break;
    default:
        luaL_error(L, "unexpected type");
        break;
    }

    return res;
}

/// Retrieve objects from table at tableInd and key
T[] getObjects(T)(lua_State* L, int tableInd, string key, const(char)* metatype)
in (tableInd > 0)
{
    lua_pushlstring(L, key.ptr, key.length);
    return getObjectsFromTop!T(L, lua_gettable(L, tableInd), metatype);
}

void printstack(lua_State* L)
{
    import std.stdio : writefln;
    import std.string : fromStringz;

    int n = lua_gettop(L);
    foreach (i; 1 .. n+1) {
        const s = luaL_typename(L, i).fromStringz.idup;
        writefln("%s = %s", i, s);
    }
}

///
T[] getObjectsFromTop(T)(lua_State* L, int typeAtTop, const(char)* metatype, bool allowFunc=true)
{
    switch (typeAtTop) {
    case LUA_TLIGHTUSERDATA:
        return [ extractObject!T(L, -1, metatype) ];
    case LUA_TTABLE:
        // top is a table containing (in principle) objects of the right type
        const tlen = luaL_len(L, -1);
        T[] res = new T[tlen];
        foreach (i; 0 .. tlen) {
            lua_rawgeti(L, -1, cast(int)(i+1));
            res[i] = extractObject!T(L, -1, metatype);
            lua_pop(L, 1);
        }
        return res;
    case LUA_TFUNCTION:
        luaEnforce(allowFunc, "function not allowed");
        lua_call(L, 0, 1);
        return getObjectsFromTop!T(L, lua_type(L, -1), metatype, false);
    case LUA_TNIL:
        return null;
    default:
        throw new LuaPrivException("unexpected value");
    }
}

/// Extract an object from the stack.
/// Fetch userdata, check if the metatype fits and reexpose to GC
T extractObject(T)(lua_State* L, int ind, const(char)*metatype)
{
    assert(lua_type(L, ind) == LUA_TLIGHTUSERDATA);
    void* loc = luaL_checkudata(L, ind, metatype);
    exposeToGC(loc);
    return cast(T)loc;
}


int buildProduct(T : Product)(lua_State* L) nothrow
{
    return box!({
        luaEnforce(
            lua_gettop(L) && lua_istable(L, 1),
            T.stringof~": expected a table argument"
        );
        const name = getStringAt(L, 1, "name");
        auto prod = new T(name);
        prod.inputs = getStringListAt(L, 1, "source");
        prod.dependencies = getStringListAt(L, 1, "dependencies");
        prod.generators = getObjects!Generator(L, 1, "generators", "chef.Generator");

        lua_pushlightuserdata(L, cast(void*)prod);
        luaL_setmetatable(L, "chef.Product");
        hideFromGC(cast(void*)prod);
        return 1;
    })(L);
}

extern(C) nothrow:

import dbuild.chef.gen;
import dbuild.chef.product;

int dbuild_lua_CppGen(lua_State* L)
{
    box!({
        auto gen = new CppGen;
        if (lua_gettop(L) && lua_istable(L, 1)) {
            gen.defines = getDefinesTable(L, 1, "defines");
            gen.includePaths = getStringListAt(L, 1, "includePaths");
            gen.cflags = getStringListAt(L, 1, "cflags");
            gen.lflags = getStringListAt(L, 1, "lflags");
        }
        lua_pushlightuserdata(L, cast(void*)gen);
        luaL_setmetatable(L, "chef.Generator");
        hideFromGC(cast(void*)gen);
    })(L);
    return 1;
}

int dbuild_lua_DGen(lua_State* L)
{
    box!({
        auto gen = new DGen;
        if (lua_gettop(L) && lua_istable(L, 1)) {
            gen.versionIdents = getStringListAt(L, 1, "versionIdents");
            gen.debugIdents = getStringListAt(L, 1, "debugIdents");
            gen.importPaths = getStringListAt(L, 1, "importPaths");
            gen.dflags = getStringListAt(L, 1, "dflags");
            gen.lflags = getStringListAt(L, 1, "lflags");
        }
        lua_pushlightuserdata(L, cast(void*)gen);
        luaL_setmetatable(L, "chef.Generator");
        hideFromGC(cast(void*)gen);
    })(L);
    return 1;
}

int dbuild_lua_Executable(lua_State* L)
{
    return buildProduct!Executable(L);
}

int dbuild_lua_StaticLibrary(lua_State* L)
{
    return buildProduct!StaticLibrary(L);
}

int dbuild_lua_DynamicLibrary(lua_State* L)
{
    return buildProduct!DynamicLibrary(L);
}

int dbuild_lua_Product(lua_State* L)
{
    return buildProduct!Product(L);
}

int dbuild_lua_Project(lua_State* L)
{
    return box!({
        luaEnforce(
            lua_gettop(L) && lua_istable(L, 1),
            "Project: expected a table argument"
        );
        const name = getStringAt(L, 1, "name", false);
        auto proj = new Project(name);
        proj.products = getObjects!Product(L, 1, "products", "chef.Product");

        lua_pushlightuserdata(L, cast(void*)proj);
        luaL_setmetatable(L, "chef.Project");
        hideFromGC(cast(void*)proj);
        return 1;
    })(L);
}
