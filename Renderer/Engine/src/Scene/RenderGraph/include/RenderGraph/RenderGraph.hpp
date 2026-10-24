// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once

#include "PassNode.hpp"

#include "Pass.hpp"
#include "TexNode.hpp"
#include "Core/MapSet.hpp"
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace rg
{

class RenderGraph;

// Declares what one pass reads and writes. Texture versions: a key has a chain of
// versions numbered from 0; a reader runs after the writer of the version it reads
// and before the writer of the next version, a writer runs after the readers of the
// previous version (or after its writer when it had none).
class RenderGraphBuilder {
public:
    RenderGraphBuilder(RenderGraph&);

    // The latest version of desc.key (created when the key is new). With `write`, a
    // fresh version when the latest one already has a writer.
    TexNode*        createTexNode(const TexNode::Desc&, bool write = false);
    void            read(TexNode*);
    void            write(TexNode*);
    const PassNode& workPassNode() const;
    void            setWorkPassNode(PassNode*);
    // Both give a never-written version 0 a bookkeeping writer, which turns every read
    // of it into a history read (the reader runs before the key's first real writer).
    void            markSelfWrite(TexNode*);
    void            markVirtualWrite(TexNode*);

private:
    RenderGraph& m_graph;
    PassNode*    m_work { nullptr };
};

class RenderGraph {
public:
    RenderGraph();
    ~RenderGraph();
    RenderGraph(const RenderGraph&)            = delete;
    RenderGraph& operator=(const RenderGraph&) = delete;
    RenderGraph(RenderGraph&&) noexcept;
    RenderGraph& operator=(RenderGraph&&) noexcept;

    PassNode* getPassNode(NodeID) const;
    TexNode*  getTexNode(NodeID) const;
    Pass*     getPass(NodeID) const;

    // Every non-virtual pass once, in an order that honours the declared reads and
    // writes. The order is built from the back, so a pass runs as late as the passes
    // that need its result allow and its buffer is not kept alive across unrelated
    // work; passes free to run in either order stay together by the target they write
    // (fewer render passes for a backend) and otherwise keep the order they were added
    // in. The order is the same on every call and every run.
    std::vector<NodeID>                topologicalOrder() const;
    std::vector<std::vector<TexNode*>> getLastReadTexs(std::span<const NodeID>) const;
    std::vector<std::string>           getCarriedOverKeys(std::span<const NodeID>) const;

    // True when `from` has to run before `to`: a chain of declared dependencies leads
    // from the pass `from` to the pass `to` (a pass does not reach itself).
    bool mustPrecede(NodeID from, NodeID to) const;

    void ToGraphviz(std::string_view path) const { m_dg.ToGraphviz(path); }

    // Calls cb(builder, pass) with a builder working on the pass `id`; false (and no
    // call) when `id` is not a pass that has its payload yet.
    template<typename CB>
    bool afterBuild(NodeID id, CB&& cb) {
        PassNode* node = getPassNode(id);
        Pass*     pass = getPass(id);
        if (node == nullptr || pass == nullptr) return false;
        RenderGraphBuilder builder(*this);
        builder.setWorkPassNode(node);
        return static_cast<bool>(cb(builder, *pass));
    }

    // Creates the node, runs cb(builder, desc) with a value-initialised TPass::Desc,
    // then builds the TPass from the filled description.
    template<typename TPass, typename CB>
    PassNode* addPass(std::string_view name, PassNode::Type type, CB&& cb) {
        PassNode* node = createPassNode(name, type);
        RenderGraphBuilder builder(*this);
        builder.setWorkPassNode(node);
        typename TPass::Desc desc {};
        cb(builder, desc);
        attachPayload(node->ID(), std::make_unique<TPass>(desc));
        return node;
    }

private:
    friend class RenderGraphBuilder;

    PassNode* createPassNode(std::string_view name, PassNode::Type type);
    TexNode*  createTexVersion(const TexNode::Desc&);
    TexNode*  createNextVersion(TexNode*);
    void      attachPayload(NodeID, std::unique_ptr<Pass>);
    void      connect(NodeID from, NodeID to);
    PassNode* createBookkeepingWriter();

    DependencyGraph                    m_dg;
    // Indexed by node id: the pass node / texture node / payload of that id, or null.
    std::vector<PassNode*>             m_pass_at;
    std::vector<TexNode*>              m_tex_at;
    std::vector<std::unique_ptr<Pass>> m_payloads;
    // Latest version of each key.
    std::unordered_map<std::string, TexNode*> m_latest;

    mutable std::vector<NodeID> m_order_cache;
    mutable bool                m_order_valid { false };
};

} // namespace rg
} // namespace wallpaper
