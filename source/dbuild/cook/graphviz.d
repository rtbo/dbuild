module dbuild.cook.graphviz;

import dbuild.cook.graph;
import dbuild.cook.recipe;

void writeRecipeGraphviz(string path, Recipe recipe)
{
    auto graph = new BuildGraph(recipe);
    writeGraphviz(path, graph);
}

package:

/// Serializes the graph into a file suitable for processing by graphviz' dot.
void writeGraphviz(string path, BuildGraph graph)
{
    import std.stdio : File;

    auto f = File(path, "w");

    f.writeln("digraph G {");

    foreach (k, n; graph.nodes) {

        string shape = "";
        if (!n.inEdge) {
            shape = " [shape=box]";
        }
        else if (!n.outEdges.length) {
            shape = " [shape=diamond]";
        }

        f.writefln(`    "%s"%s`, n.path, shape);
    }

    foreach (e; graph.edges) {
        foreach (i; e.inputs) {
            foreach (o; e.allOutputs) {
                f.writefln(`    "%s" -> "%s"`, o.path, i.path);
            }
        }
        foreach (i; e.implicitInputs) {
            foreach (o; e.allOutputs) {
                f.writefln(`    "%s" -> "%s" [style=dashed]`, o.path, i.path);
            }
        }
        foreach (i; e.orderOnlyInputs) {
            foreach (o; e.allOutputs) {
                f.writefln(`    "%s" -> "%s" [style=dotted]`, o.path, i.path);
            }
        }
    }

    f.writeln("}");
}
