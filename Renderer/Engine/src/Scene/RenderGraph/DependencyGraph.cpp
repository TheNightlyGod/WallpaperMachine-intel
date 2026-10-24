// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "DependencyGraph.hpp"

#include <algorithm>
#include <fstream>
#include <functional>
#include <queue>

namespace wallpaper::rg
{

namespace
{
// Kahn's algorithm over adjacency lists. `forced` (nodes still waiting when nothing is
// ready) are taken in ascending id order, so the result always holds every node once.
std::vector<NodeID> KahnOrder(const std::vector<std::vector<NodeID>>& out,
                              const std::vector<std::vector<NodeID>>& in) {
    const size_t        count = out.size();
    std::vector<size_t> waiting(count);
    std::vector<char>   placed(count, 0);
    std::priority_queue<NodeID, std::vector<NodeID>, std::greater<>> ready;
    for (NodeID i = 0; i < count; ++i) {
        waiting[i] = in[i].size();
        if (waiting[i] == 0) ready.push(i);
    }
    std::vector<NodeID> order;
    order.reserve(count);
    NodeID lowest_unplaced = 0;
    auto   place           = [&](NodeID id) {
        placed[id] = 1;
        order.push_back(id);
        for (NodeID next : out[id]) {
            if (placed[next] || waiting[next] == 0) continue;
            if (--waiting[next] == 0) ready.push(next);
        }
    };
    while (order.size() < count) {
        if (! ready.empty()) {
            NodeID id = ready.top();
            ready.pop();
            if (placed[id]) continue;
            place(id);
            continue;
        }
        while (lowest_unplaced < count && placed[lowest_unplaced]) ++lowest_unplaced;
        if (lowest_unplaced >= count) break;
        place(lowest_unplaced);
    }
    return order;
}
} // namespace

std::string EscapeGraphvizLabel(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (char c : text) {
        if (c == '"' || c == '\\') out.push_back('\\');
        if (c == '\n') {
            out += "\\n";
            continue;
        }
        out.push_back(c);
    }
    return out;
}

std::string DependencyGraph::Node::ToGraphviz() const {
    return GraphID() + " [label=\"" + GraphID() + "\"];";
}

std::vector<NodeID> DependencyGraph::GetNodeOut(NodeID id) const {
    return id < m_out.size() ? m_out[id] : std::vector<NodeID> {};
}

std::vector<NodeID> DependencyGraph::GetNodeIn(NodeID id) const {
    return id < m_in.size() ? m_in[id] : std::vector<NodeID> {};
}

NodeID DependencyGraph::AddNode(std::unique_ptr<Node>&& node) {
    const NodeID id = m_nodes.size();
    if (node) node->m_id = id;
    m_nodes.push_back(std::move(node));
    m_out.emplace_back();
    m_in.emplace_back();
    return id;
}

void DependencyGraph::Connect(NodeID from, NodeID to) {
    if (from >= m_nodes.size() || to >= m_nodes.size()) return;
    auto& out = m_out[from];
    auto  at  = std::lower_bound(out.begin(), out.end(), to);
    if (at != out.end() && *at == to) return;
    out.insert(at, to);
    auto& in = m_in[to];
    in.insert(std::lower_bound(in.begin(), in.end(), from), from);
    ++m_edge_count;
}

std::vector<NodeID> DependencyGraph::TopologicalOrder() const {
    return KahnOrder(m_out, m_in);
}

bool DependencyGraph::HasCycle() const {
    const size_t        count = m_nodes.size();
    std::vector<size_t> waiting(count);
    std::vector<NodeID> stack;
    for (NodeID i = 0; i < count; ++i) {
        waiting[i] = m_in[i].size();
        if (waiting[i] == 0) stack.push_back(i);
    }
    size_t visited = 0;
    while (! stack.empty()) {
        NodeID id = stack.back();
        stack.pop_back();
        ++visited;
        for (NodeID next : m_out[id])
            if (--waiting[next] == 0) stack.push_back(next);
    }
    return visited != count;
}

void DependencyGraph::ToGraphviz(std::string_view path) const {
    std::ofstream file { std::string(path), std::ios::trunc };
    if (! file) return;
    file << "digraph render_graph {\n";
    for (const auto& node : m_nodes) {
        if (node) file << "    " << node->ToGraphviz() << "\n";
    }
    for (NodeID from = 0; from < m_out.size(); ++from) {
        for (NodeID to : m_out[from]) file << "    n" << from << " -> n" << to << ";\n";
    }
    file << "}\n";
}

} // namespace wallpaper::rg
