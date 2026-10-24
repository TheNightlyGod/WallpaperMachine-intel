// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once
#include "DependencyGraph.hpp"
#include <string>
#include <vector>

namespace wallpaper
{
namespace rg
{

class RenderGraphBuilder;
class PassNode;

class TexNode : public DependencyGraph::Node {
public:
    enum class TexType {
        Imported,
        Temp
    };
    struct Desc {
        std::string name;
        std::string key;
        TexType type;
    };
    // Creates version 0 of a key inside the graph; the graph owns the node.
    static TexNode* addTexNode(DependencyGraph& dg, const Desc& type);
    // Creates the version after `pre` (after the last of its chain), inheriting its
    // name, key and type. Null when `pre` is null.
    static TexNode* addNewVersion(DependencyGraph& dg, TexNode* pre);

    TexNode() = default;

    TexType type() const;
    std::string_view name() const;
    std::string_view key() const;
    size_t version() const;
    PassNode* writer() const;
    Desc genDesc() const;

    TexNode* preVer() const;
    TexNode* nextVer() const;

    // The passes that declared a read of exactly this version (render targets only).
    const std::vector<PassNode*>& readers() const { return m_readers; }

    void setName(std::string_view);
    void setKey(std::string_view);
    void setWriter(PassNode*);

    std::string ToGraphviz() const override;

private:
    friend class RenderGraphBuilder;

    std::string m_name;
    std::string m_key;
    TexType     m_type { TexType::Temp };
    size_t      m_version { 0 };
    PassNode*   m_writer { nullptr };
    TexNode*    m_pre { nullptr };
    TexNode*    m_next { nullptr };
    // Passes that read exactly this version (only recorded for render targets).
    std::vector<PassNode*> m_readers;
};
}
}
