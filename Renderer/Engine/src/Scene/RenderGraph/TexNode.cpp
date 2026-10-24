// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "TexNode.hpp"
#include "PassNode.hpp"

namespace wallpaper::rg
{

TexNode* TexNode::addTexNode(DependencyGraph& dg, const Desc& desc) {
    auto node    = std::make_unique<TexNode>();
    node->m_name = desc.name;
    node->m_key  = desc.key;
    node->m_type = desc.type;
    TexNode* raw = node.get();
    dg.AddNode(std::move(node));
    return raw;
}

TexNode* TexNode::addNewVersion(DependencyGraph& dg, TexNode* pre) {
    if (pre == nullptr) return nullptr;
    while (pre->m_next != nullptr) pre = pre->m_next;
    TexNode* fresh   = addTexNode(dg, pre->genDesc());
    fresh->m_version = pre->m_version + 1;
    fresh->m_pre     = pre;
    pre->m_next      = fresh;
    return fresh;
}

TexNode::Desc TexNode::genDesc() const {
    return Desc { .name = m_name, .key = m_key, .type = m_type };
}

TexNode::TexType TexNode::type() const {
    return m_type;
}

std::string_view TexNode::name() const {
    return m_name;
}

std::string_view TexNode::key() const {
    return m_key;
}

size_t TexNode::version() const {
    return m_version;
}

PassNode* TexNode::writer() const {
    return m_writer;
}

TexNode* TexNode::preVer() const {
    return m_pre;
}

TexNode* TexNode::nextVer() const {
    return m_next;
}

void TexNode::setName(std::string_view name) {
    m_name = std::string(name);
}

void TexNode::setKey(std::string_view key) {
    m_key = std::string(key);
}

void TexNode::setWriter(PassNode* writer) {
    m_writer = writer;
}

std::string TexNode::ToGraphviz() const {
    return GraphID() + " [shape=ellipse label=\"" + EscapeGraphvizLabel(m_key) + " v" +
           std::to_string(m_version) + "\"];";
}

} // namespace wallpaper::rg
