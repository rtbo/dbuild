module dbuild.chef;

public import dbuild.chef.gen;
public import dbuild.chef.product;
public import dbuild.chef.project;

import dbuild.cook.recipe;

enum BuildType
{
    debug_,
    release,
}

/// CPU architecture
enum Arch
{
    host,
    x86,
    x86_64,
}

/// get the number of bits in a pointer for arch
@property uint pointerSize(in Arch arch) pure
{
    alias voidp = void*;

    final switch (arch) {
    case Arch.host: return voidp.sizeof * 8;
    case Arch.x86: return 32;
    case Arch.x86_64: return 64;
    }
}

class Chef
{
    Project _project;
    Arch _arch;
    BuildType _buildType;
    string _buildDir;
    string _installDir;

    this(Project project)
    {
        _project = project;
    }

    @property Arch arch()
    {
        return _arch;
    }
    @property void arch(in Arch arch)
    {
        _arch = arch;
    }

    @property BuildType buildType()
    {
        return _buildType;
    }
    @property void buildType(in BuildType buildType)
    {
        _buildType = buildType;
    }

    @property string buildDir()
    {
        return _buildDir;
    }
    @property void buildDir(in string buildDir)
    {
        _buildDir = buildDir;
    }

    @property string installDir()
    {
        return _installDir;
    }
    @property void installDir(in string installDir)
    {
        _installDir = installDir;
    }

    void setDirs(in string buildDir, in string installDir)
    {
        _buildDir = buildDir;
        _installDir = installDir;
    }

    Recipe buildRecipe()
    {
        import std.algorithm : copy, sort, uniq;
        Rule[] rules;
        Build[] builds;

        foreach (prod; _project.products) {
            rules ~= prod.issueCookRules(this);
            builds ~= prod.issueCookBuilds(this);
        }

        rules.sort!("a.name < b.name")();
        rules.length -= rules.uniq().copy(rules).length;

        return Recipe(rules, builds).withCacheDir(buildDir);
    }
}
