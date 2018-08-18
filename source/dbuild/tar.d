/// implementation of tar file extraction
module dbuild.tar;

/// print all entries names to stdout
void listFiles(in string archive)
{
    import std.exception : enforce;
    import std.stdio : File, writefln;

    auto tarF = File(archive, "rb");

    int bypass;

    foreach (chunk; tarF.byChunk(blockSize)) {
        if (bypass) {
            --bypass;
            continue;
        }

        enforce(chunk.length == blockSize);
        TarHeader *hp = cast(TarHeader*)&chunk[0];

        writefln("%s: %s", hp.typeFlag, trunc(hp.filename));

        auto sz = octalStrToLong(hp.size);
        while (sz > 0) {
            bypass++;
            if (sz > blockSize) sz -= blockSize;
            else sz = 0;
        }
    }
}

/// Check whether the archive contains a single or multiple root directories.
/// Useful to determine if archive can be extracted "here" or within another directory
bool isSingleRootDir(in string archive, out string rootDir)
{
    import std.algorithm : findSplit;
    import std.exception : enforce;
    import std.stdio : File;
    import std.string : strip;

    auto tarF = File(archive, "rb");

    int bypass;

    foreach (chunk; tarF.byChunk(blockSize)) {
        if (bypass) {
            --bypass;
            continue;
        }

        enforce(chunk.length == blockSize);
        TarHeader *hp = cast(TarHeader*)&chunk[0];

        if (hp.typeFlag == TypeFlag.directory /+ || hp.typeFlag == TypeFlag.file +/) {
            const name = trunc(hp.filename);
            const rd = findSplit(name, "/")[0];
            if (!rootDir.length) {
                rootDir = rd;
            }
            else {
                if (rd != rootDir) return false;
            }
        }

        auto sz = octalStrToLong(hp.size);
        while (sz > 0) {
            bypass++;
            if (sz > blockSize) sz -= blockSize;
            else sz = 0;
        }
    }
    return true;
}

/// Extract a tar file to a directory.
void extractTo(in string archive, in string directory)
{
    import std.exception : enforce;
    import std.file : mkdir, mkdirRecurse, setAttributes;
    import std.path : buildPath;
    import std.stdio : File;

    mkdirRecurse(directory);

    auto f = File(archive, "rb");

    ubyte[blockSize] block;
    ubyte[blockSize] fileblock;

    int numNullBlocks;
    while (numNullBlocks < 2) {

        auto hb = f.rawRead(block[]);
        if (!hb.length) break;

        if (isNullBlock(hb)) {
            numNullBlocks ++;
            continue;
        }

        enforce(hb.length == blockSize);
        TarHeader* th = cast(TarHeader*)(&hb[0]);

        // Check the checksum
        if(!th.confirmChecksum()) {
            throw new Exception("Invalid checksum for "~archive);
        }

        string filename = trunc(th.filename);
        if (th.magic == posixMagicNum) {
            filename = trunc(th.prefix) ~ filename;
        }
        auto sz = cast(size_t)octalStrToLong(th.size);
        
        // TODO mode
        if (th.typeFlag == TypeFlag.directory) {
            const path = buildPath(directory, filename);
            mkdir(path);
        }
        else if (th.typeFlag == TypeFlag.file) {
            const path = buildPath(directory, filename);

            {
                auto nf = File(path, "wb");
                while(sz > 0) {
                    auto fb = f.rawRead(fileblock[]);
                    const copyLen = sz > blockSize ? blockSize : sz;
                    nf.rawWrite(fb[0 .. copyLen]);
                    sz -= copyLen;
                }
            }

            const mode = octalStrToInt(th.mode);
            setAttributes(path, mode);
        }

    }
}

private enum blockSize = 512;

private enum TypeFlag : ubyte
{
    altFile = 0,
    file = '0',
    hardLink = '1',
    symbolicLink = '2',
    characterSpecial = '3',
    blockSpecial = '4',
    directory = '5',
    fifo = '6',
    contiguousFile = '7',
}

private struct Uint12
{
    uint hi;
    ulong lo;
}

private struct TarHeader
{
    char[100] filename;
    char[8] mode;
    char[8] ownerId;
    char[8] groupId;
    char[12] size;
    char[12] modificationTime;
    char[8] checksum;
    TypeFlag typeFlag;
    char[100] linkedFilename;
    
    char[6] magic;
    char[2] tarVersion;
    char[32] owner;
    char[32] group;
    char[8] deviceMajorNumber;
    char[8] deviceMinorNumber;
    char[155] prefix;
    char[12] padding;
    
    bool confirmChecksum()
    {
        uint apparentChecksum = octalStrToInt(checksum);
        uint currentSum = calculateUnsignedChecksum();
        
        if(apparentChecksum != currentSum)
        {
            // Handle old tars which use a broken implementation that calculated the
            // checksum incorrectly (using signed chars instead of unsigned).
            currentSum = calculateSignedChecksum();
            if(apparentChecksum != currentSum)
            {
                return false;
            }
        }
        return true;
    }
    
    void nullify()
    {
        filename = 0;
        mode = 0;
        ownerId = 0;
        groupId = 0;
        size = 0;
        modificationTime = 0;
        checksum = 0;
        typeFlag = cast(TypeFlag)0;
        magic = 0;
        tarVersion = 0;
        owner = 0;
        group = 0;
        deviceMajorNumber = 0;
        deviceMinorNumber = 0;
        prefix = 0;
        padding = 0;
    }
    
    uint calculateUnsignedChecksum()
    {
        uint sum;
        sum += unsignedSum(filename);
        sum += unsignedSum(mode);
        sum += unsignedSum(ownerId);
        sum += unsignedSum(groupId);
        sum += unsignedSum(size);
        sum += unsignedSum(modificationTime);
        sum += 32 * 8; // checksum is treated as all blanks
        sum += typeFlag;
        sum += unsignedSum(linkedFilename);
        sum += unsignedSum(magic);
        sum += unsignedSum(tarVersion); 
        sum += unsignedSum(owner);
        sum += unsignedSum(group);
        sum += unsignedSum(deviceMajorNumber);
        sum += unsignedSum(deviceMinorNumber);
        sum += unsignedSum(prefix);
        return sum;
    }
    
    uint calculateSignedChecksum()
    {
        uint sum;
        sum += signedSum(filename);
        sum += signedSum(mode);
        sum += signedSum(ownerId);
        sum += signedSum(groupId);
        sum += signedSum(size);
        sum += signedSum(modificationTime);
        sum += 32 * 8; // checksum is treated as all blanks
        sum += typeFlag;
        sum += signedSum(linkedFilename);
        sum += signedSum(magic);
        sum += signedSum(tarVersion); 
        sum += signedSum(owner);
        sum += signedSum(group);
        sum += signedSum(deviceMajorNumber);
        sum += signedSum(deviceMinorNumber);
        sum += signedSum(prefix);
        return sum;
    }

    private static uint unsignedSum(char[] values)
    {
        uint result;
        foreach(char c ; values)
        {
            result += c;
        }
        return result;
    }
    
    private static uint signedSum(char[] values)
    {
        uint result;
        foreach(byte b ; cast(byte[])values)
        {
            result += b;
        }
        return result;
    }
}

static assert (TarHeader.sizeof == blockSize);

private string posixMagicNum = "ustar\0";  

private bool isNullBlock(const(ubyte)[] block) 
{
    if (block.length != blockSize) return false;
    foreach(b; block) {
        if (b != 0) return false;
    }
    return true;
}

private uint octalStrToInt(char[] octal)
{
    import std.format : formattedRead;
    import std.string : strip;

    string s = cast(string)(strip(octal));
    uint result;
    formattedRead(s, "%o ", &result);
    return result;
}

private ulong octalStrToLong(char[] octal)
{
    import std.format : formattedRead;
    import std.string : strip;

    string s = cast(string)(strip(octal));
    ulong result;
    formattedRead(s, "%o ", &result);
    return result;
}

private char[] strToBytes(string str, uint length)
{
    import std.algorithm : min;

    char[] result = new char[length];
    result[0 .. min(str.length, length)] = str;
    result[str.length .. $] = 0;
    return result;
}
    
private string trunc(char[] input)
{
    for(size_t i=0; i < input.length; ++i)
    {
        if(input[i] == '\0')
        {
            return input[0 .. i].idup;
        }
    }
    return input.idup;
}
