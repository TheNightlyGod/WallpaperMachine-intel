// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "PassNode.hpp"

namespace wallpaper::rg
{

PassNode* PassNode::addPassNode(DependencyGraph& dg, PassNode::Type type) {
    auto node = std::make_unique<PassNode>();
    node->m_type = type;
    PassNode* raw = node.get();
    dg.AddNode(std::move(node));
    return raw;
}

PassNode::Type PassNode::type() const {
    return m_type;
}

std::string_view PassNode::name() const {
    return m_name;
}

void PassNode::setName(std::string_view name) {
    m_name = std::string(name);
}

std::string PassNode::ToGraphviz() const {
    return GraphID() + " [shape=box label=\"" + EscapeGraphvizLabel(m_name) + "\"];";
}

} // namespace wallpaper::rg
