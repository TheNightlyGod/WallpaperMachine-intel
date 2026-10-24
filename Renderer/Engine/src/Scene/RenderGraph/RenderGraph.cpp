// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "RenderGraph.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <set>

namespace wallpaper::rg
{

namespace
{
template<typename T>
void PushUnique(std::vector<T*>& list, T* item) {
    if (std::find(list.begin(), list.end(), item) == list.end()) list.push_back(item);
}

// Picks the order passes run in once their dependencies are fixed. The order is built
// from the back: a pass is placed only after every pass that has to follow it, so a
// pass lands as late as its dependants allow, in front of the first pass that needs
// its result, and a buffer is written close to where it is read instead of being kept
// alive across work it has nothing to do with. Buffers whose uses do not overlap can
// then be given one image.
//
// Among the passes that may go next (the ones nothing unplaced has to follow), the one
// placed in front of the pass placed last is
//  1. a pass writing the same target, because a backend renders consecutive passes into
//     one target in a single render pass and every extra one stores and reloads the
//     whole image;
//  2. else the one with the largest id, so passes with nothing to tie them keep the
//     order they were added in.
class PassScheduler {
public:
    PassScheduler(const DependencyGraph& edges, std::vector<char> is_pass,
                  std::vector<char> is_virtual, std::vector<size_t> target_of)
        : m_edges(edges)
        , m_is_pass(std::move(is_pass))
        , m_is_virtual(std::move(is_virtual))
        , m_target_of(std::move(target_of)) {}

    std::vector<NodeID> run() {
        const size_t count = m_is_pass.size();
        m_blockers.assign(count, 0);
        m_placed.assign(count, 0);
        size_t pending      = 0;
        size_t target_count = 0;
        for (NodeID id = 0; id < count; ++id) {
            if (! counts(id)) continue;
            ++pending;
            for (NodeID next : m_edges.GetNodeOut(id))
                if (counts(next)) ++m_blockers[id];
            if (m_target_of[id] != kNone) target_count = std::max(target_count, m_target_of[id] + 1);
        }
        m_ready_by_target.assign(target_count, std::set<NodeID> {});
        for (NodeID id = 0; id < count; ++id)
            if (counts(id) && m_blockers[id] == 0) makeReady(id);

        std::vector<NodeID> backwards;
        backwards.reserve(pending);
        NodeID cursor = count;
        while (backwards.size() < pending) {
            NodeID next = kNoPass;
            if (m_last != kNoPass && m_target_of[m_last] != kNone) {
                const auto& same = m_ready_by_target[m_target_of[m_last]];
                if (! same.empty()) next = *same.rbegin();
            }
            if (next == kNoPass && ! m_ready.empty()) next = *m_ready.rbegin();
            if (next == kNoPass) {
                // Only a dependency cycle leaves nothing ready: the largest pass not
                // yet placed breaks it.
                while (cursor > 0 && (! counts(cursor - 1) || m_placed[cursor - 1])) --cursor;
                next = cursor - 1;
            }
            place(next, backwards);
        }
        std::reverse(backwards.begin(), backwards.end());
        return backwards;
    }

private:
    static constexpr size_t kNone   = std::numeric_limits<size_t>::max();
    static constexpr NodeID kNoPass = std::numeric_limits<NodeID>::max();

    // Virtual passes only carry dependencies and never reach the order. They have no
    // incoming edges, so leaving them out cannot loosen a constraint between others.
    bool counts(NodeID id) const { return m_is_pass[id] && ! m_is_virtual[id]; }

    void makeReady(NodeID id) {
        m_ready.insert(id);
        if (m_target_of[id] != kNone) m_ready_by_target[m_target_of[id]].insert(id);
    }

    void place(NodeID id, std::vector<NodeID>& backwards) {
        m_ready.erase(id);
        if (m_target_of[id] != kNone) m_ready_by_target[m_target_of[id]].erase(id);
        m_placed[id] = 1;
        backwards.push_back(id);
        m_last = id;
        for (NodeID before : m_edges.GetNodeIn(id)) {
            if (! counts(before) || m_placed[before] || m_blockers[before] == 0) continue;
            if (--m_blockers[before] == 0) makeReady(before);
        }
    }

    const DependencyGraph&        m_edges;
    std::vector<char>             m_is_pass;
    std::vector<char>             m_is_virtual;
    std::vector<size_t>           m_target_of;
    // Per pass: how many passes that must follow it are not placed yet.
    std::vector<size_t>           m_blockers;
    std::vector<char>             m_placed;
    // Passes ready to be placed, all of them and by the target they write.
    std::set<NodeID>              m_ready;
    std::vector<std::set<NodeID>> m_ready_by_target;
    // The pass placed last.
    NodeID                        m_last { kNoPass };
};
} // namespace

RenderGraph::RenderGraph()                                 = default;
RenderGraph::~RenderGraph()                                = default;
RenderGraph::RenderGraph(RenderGraph&&) noexcept           = default;
RenderGraph& RenderGraph::operator=(RenderGraph&&) noexcept = default;

PassNode* RenderGraph::getPassNode(NodeID id) const {
    return id < m_pass_at.size() ? m_pass_at[id] : nullptr;
}

TexNode* RenderGraph::getTexNode(NodeID id) const {
    return id < m_tex_at.size() ? m_tex_at[id] : nullptr;
}

Pass* RenderGraph::getPass(NodeID id) const {
    return id < m_payloads.size() ? m_payloads[id].get() : nullptr;
}

PassNode* RenderGraph::createPassNode(std::string_view name, PassNode::Type type) {
    PassNode* node = PassNode::addPassNode(m_dg, type);
    node->setName(name);
    const NodeID id = node->ID();
    m_pass_at.resize(id + 1, nullptr);
    m_tex_at.resize(id + 1, nullptr);
    m_payloads.resize(id + 1);
    m_pass_at[id] = node;
    m_order_valid = false;
    return node;
}

TexNode* RenderGraph::createTexVersion(const TexNode::Desc& desc) {
    TexNode* tex = TexNode::addTexNode(m_dg, desc);
    const NodeID id = tex->ID();
    m_pass_at.resize(id + 1, nullptr);
    m_tex_at.resize(id + 1, nullptr);
    m_payloads.resize(id + 1);
    m_tex_at[id]       = tex;
    m_latest[desc.key] = tex;
    return tex;
}

TexNode* RenderGraph::createNextVersion(TexNode* pre) {
    TexNode* tex = TexNode::addNewVersion(m_dg, pre);
    if (tex == nullptr) return nullptr;
    const NodeID id = tex->ID();
    m_pass_at.resize(id + 1, nullptr);
    m_tex_at.resize(id + 1, nullptr);
    m_payloads.resize(id + 1);
    m_tex_at[id]                  = tex;
    m_latest[std::string(tex->key())] = tex;
    return tex;
}

void RenderGraph::attachPayload(NodeID id, std::unique_ptr<Pass> pass) {
    if (id >= m_payloads.size()) return;
    m_payloads[id] = std::move(pass);
}

void RenderGraph::connect(NodeID from, NodeID to) {
    m_dg.Connect(from, to);
    m_order_valid = false;
}

PassNode* RenderGraph::createBookkeepingWriter() {
    PassNode* node = createPassNode("virtual write", PassNode::Type::Virtual);
    attachPayload(node->ID(), std::make_unique<VirtualPass>(VirtualPass::Desc {}));
    return node;
}

std::vector<NodeID> RenderGraph::topologicalOrder() const {
    if (m_order_valid) return m_order_cache;

    // Order the passes alone: a texture node is only a hand-over point, so a pass
    // that writes a version precedes every pass that reads it, and the ids of texture
    // nodes must not influence which pass goes first.
    DependencyGraph passes;
    for (NodeID id = 0; id < m_dg.NodeNum(); ++id)
        passes.AddNode(std::make_unique<DependencyGraph::Node>());
    for (NodeID from = 0; from < m_pass_at.size(); ++from) {
        if (m_pass_at[from] == nullptr) continue;
        for (NodeID mid : m_dg.GetNodeOut(from)) {
            if (m_pass_at[mid] != nullptr) {
                if (mid != from) passes.Connect(from, mid);
                continue;
            }
            for (NodeID to : m_dg.GetNodeOut(mid))
                if (to != from && m_pass_at[to] != nullptr) passes.Connect(from, to);
        }
    }
    // The target a pass draws into, as a dense index per key.
    std::vector<char>                            is_pass(m_dg.NodeNum(), 0);
    std::vector<char>                            is_virtual(m_dg.NodeNum(), 0);
    std::vector<size_t>                          target_of(m_dg.NodeNum(), SIZE_MAX);
    std::unordered_map<std::string_view, size_t> target_index;
    for (NodeID id = 0; id < m_pass_at.size(); ++id) {
        const PassNode* pass = m_pass_at[id];
        if (pass == nullptr) continue;
        is_pass[id]    = 1;
        is_virtual[id] = pass->type() == PassNode::Type::Virtual;
        if (is_virtual[id] || pass->m_writes.empty()) continue;
        target_of[id] = target_index.try_emplace(pass->m_writes.front()->key(), target_index.size())
                            .first->second;
    }
    const std::vector<NodeID> order =
        PassScheduler(passes, std::move(is_pass), std::move(is_virtual), std::move(target_of)).run();
    m_order_cache = order;
    m_order_valid = true;
    return order;
}

bool RenderGraph::mustPrecede(NodeID from, NodeID to) const {
    if (getPassNode(from) == nullptr || getPassNode(to) == nullptr || from == to) return false;
    std::vector<char>   seen(m_dg.NodeNum(), 0);
    std::vector<NodeID> stack { from };
    seen[from] = 1;
    while (! stack.empty()) {
        const NodeID at = stack.back();
        stack.pop_back();
        for (NodeID next : m_dg.GetNodeOut(at)) {
            if (next == to) return true;
            if (seen[next]) continue;
            seen[next] = 1;
            stack.push_back(next);
        }
    }
    return false;
}

std::vector<std::vector<TexNode*>> RenderGraph::getLastReadTexs(std::span<const NodeID> nodes) const {
    std::vector<std::vector<TexNode*>> result(nodes.size());
    // The position of the last pass in the span that touches each key.
    std::unordered_map<std::string_view, size_t> last;
    auto touched = [&](const PassNode& pass, auto&& visit) {
        for (TexNode* tex : pass.m_reads) visit(tex);
        for (TexNode* tex : pass.m_writes) visit(tex);
    };
    for (size_t i = 0; i < nodes.size(); ++i) {
        const PassNode* pass = getPassNode(nodes[i]);
        if (pass == nullptr || pass->type() == PassNode::Type::Virtual) continue;
        touched(*pass, [&](TexNode* tex) { last[tex->key()] = i; });
    }
    for (size_t i = 0; i < nodes.size(); ++i) {
        const PassNode* pass = getPassNode(nodes[i]);
        if (pass == nullptr || pass->type() == PassNode::Type::Virtual) continue;
        touched(*pass, [&](TexNode* tex) {
            if (last[tex->key()] != i) return;
            for (const TexNode* have : result[i])
                if (have->key() == tex->key()) return;
            result[i].push_back(tex);
        });
    }
    return result;
}

std::vector<std::string> RenderGraph::getCarriedOverKeys(std::span<const NodeID> nodes) const {
    struct KeyState {
        bool candidate { false };
        bool carried { false };
    };
    std::unordered_map<std::string_view, KeyState> state;
    std::vector<std::string_view>                  first_read_order;
    for (NodeID id : nodes) {
        const PassNode* pass = getPassNode(id);
        if (pass == nullptr || pass->type() == PassNode::Type::Virtual) continue;
        for (const TexNode* tex : pass->m_reads) {
            if (state.contains(tex->key())) continue;
            const bool temp  = tex->type() == TexNode::TexType::Temp;
            state[tex->key()] = KeyState { .candidate = temp };
            if (temp) first_read_order.push_back(tex->key());
        }
        for (const TexNode* tex : pass->m_writes) {
            auto at = state.find(tex->key());
            if (at == state.end()) {
                state[tex->key()] = KeyState {};
            } else if (at->second.candidate) {
                at->second.carried = true;
            }
        }
    }
    std::vector<std::string> keys;
    for (std::string_view key : first_read_order)
        if (state[key].carried) keys.emplace_back(key);
    return keys;
}

RenderGraphBuilder::RenderGraphBuilder(RenderGraph& graph): m_graph(graph) {}

TexNode* RenderGraphBuilder::createTexNode(const TexNode::Desc& desc, bool write) {
    auto it = m_graph.m_latest.find(desc.key);
    if (it == m_graph.m_latest.end()) return m_graph.createTexVersion(desc);
    TexNode* latest = it->second;
    if (write && latest->writer() != nullptr) return m_graph.createNextVersion(latest);
    return latest;
}

void RenderGraphBuilder::setWorkPassNode(PassNode* pass) {
    m_work = pass;
}

const PassNode& RenderGraphBuilder::workPassNode() const {
    static const PassNode placeholder {};
    return m_work != nullptr ? *m_work : placeholder;
}

void RenderGraphBuilder::markSelfWrite(TexNode* tex) {
    markVirtualWrite(tex);
}

void RenderGraphBuilder::markVirtualWrite(TexNode* tex) {
    if (tex == nullptr || tex->version() != 0 || tex->writer() != nullptr) return;
    PassNode* bookkeeping = m_graph.createBookkeepingWriter();
    tex->setWriter(bookkeeping);
    bookkeeping->m_writes.push_back(tex);
    m_graph.connect(bookkeeping->ID(), tex->ID());
}

void RenderGraphBuilder::read(TexNode* tex) {
    if (tex == nullptr || m_work == nullptr) return;
    const bool render_target = tex->type() == TexNode::TexType::Temp;
    // A render target nothing has written yet holds the previous frame's picture.
    if (render_target) markVirtualWrite(tex);
    PushUnique(m_work->m_reads, tex);
    if (tex->writer() == m_work) return;
    m_graph.connect(tex->ID(), m_work->ID());
    if (! render_target) return;
    PushUnique(tex->m_readers, m_work);
    // An old version stays readable: its reader still goes before the next writer.
    const TexNode* next = tex->nextVer();
    if (next != nullptr && next->writer() != nullptr && next->writer() != m_work)
        m_graph.connect(m_work->ID(), next->writer()->ID());
}

void RenderGraphBuilder::write(TexNode* tex) {
    if (tex == nullptr || m_work == nullptr) return;
    PassNode* old_writer = tex->writer();
    if (old_writer != nullptr && old_writer != m_work) m_graph.connect(old_writer->ID(), m_work->ID());
    if (const TexNode* prev = tex->preVer()) {
        bool others = false;
        for (PassNode* reader : prev->m_readers) {
            if (reader == m_work) continue;
            others = true;
            m_graph.connect(reader->ID(), m_work->ID());
        }
        if (! others && prev->writer() != nullptr && prev->writer() != m_work)
            m_graph.connect(prev->writer()->ID(), m_work->ID());
    }
    tex->setWriter(m_work);
    PushUnique(m_work->m_writes, tex);
    m_graph.connect(m_work->ID(), tex->ID());
}

} // namespace wallpaper::rg
