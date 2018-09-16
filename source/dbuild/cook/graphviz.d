module dbuild.cook.graphviz;

import dbuild.cook.graph;

/// Serializes the graph into a file suitable for processing by graphviz' dot.
void writeGraphviz(string path, BuildGraph graph)
{
    import std.stdio : File;

    auto f = File(path, "w");

    f.writeln("digraph G {");

    foreach (k, n; graph.nodes) {
        if (n.inEdge) {
            foreach (i; n.inEdge.allInputs) {
                f.writefln(`    "%s" -> "%s";`, n.path, i.path);
            }
        }
        else {
            f.writefln(`    "%s";`, n.path);
        }
    }

    f.writeln("}");
}
