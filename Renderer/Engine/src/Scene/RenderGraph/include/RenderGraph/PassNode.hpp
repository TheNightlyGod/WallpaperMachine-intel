// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once
#include "DependencyGraph.hpp"
#include <string>
#include <vector>

namespace wallpaper
{
namespace rg
{

class TexNode;
class PassNode : public DependencyGraph::Node {
public:
    enum class Type {
        CustomShader,
        Copy,
        Clear,
        Virtual
    };
    // Creates a pass node of this type inside the graph (named "unknown pass") and
    // returns it; the graph owns it.
    static PassNode* addPassNode(DependencyGraph& dg, Type type);

    PassNode() = default;

    Type type() const;
    std::string_view name() const;

    void setName(std::string_view);

    std::string ToGraphviz() const override;

private:
    friend class RenderGraph;
    friend class RenderGraphBuilder;

    Type                  m_type { Type::Virtual };
    std::string           m_name { "unknown pass" };
    // The texture versions this pass declared it reads / writes, in declaration order.
    std::vector<TexNode*> m_reads;
    std::vector<TexNode*> m_writes;
};
}
}
