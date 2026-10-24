// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once
#include <cstdint>
#include <vector>
#include <numeric>
#include <memory>
#include <unordered_set>
#include <string>
#include <string_view>

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace rg
{

typedef size_t NodeID;

// Escapes a text for use inside a double-quoted Graphviz label.
std::string EscapeGraphvizLabel(std::string_view);

// Directed graph of owned nodes. Ids are dense and follow insertion order. Edges
// are kept as sorted adjacency lists in both directions, so neighbour queries
// cost the degree of the node and never scan the graph.
class DependencyGraph : NoCopy {
public:
    class Node : NoCopy {
    public:
        Node()          = default;
        virtual ~Node() = default;

        NodeID ID() const { return m_id; }
        std::string GraphID() const { return "n" + std::to_string(m_id); }
        // One Graphviz statement (no trailing newline) that declares this node.
        virtual std::string ToGraphviz() const;

    private:
        friend class DependencyGraph;
        NodeID m_id { 0 };
    };

    DependencyGraph()  = default;
    ~DependencyGraph() = default;

    DependencyGraph(DependencyGraph&& other) noexcept
        : NoCopy(),
          m_nodes(std::move(other.m_nodes)),
          m_out(std::move(other.m_out)),
          m_in(std::move(other.m_in)),
          m_edge_count(other.m_edge_count) {
        other.m_edge_count = 0;
    }
    DependencyGraph& operator=(DependencyGraph&& other) noexcept {
        if (this != &other) {
            m_nodes            = std::move(other.m_nodes);
            m_out              = std::move(other.m_out);
            m_in               = std::move(other.m_in);
            m_edge_count       = other.m_edge_count;
            other.m_edge_count = 0;
        }
        return *this;
    }

    size_t NodeNum() const { return m_nodes.size(); }
    size_t EdgeNum() const { return m_edge_count; }
    Node*  GetNode(NodeID id) const { return id < m_nodes.size() ? m_nodes[id].get() : nullptr; }

    // Neighbour ids in ascending order; empty for an id that does not exist.
    std::vector<NodeID> GetNodeOut(NodeID) const;
    std::vector<NodeID> GetNodeIn(NodeID) const;

    NodeID AddNode(std::unique_ptr<Node>&&);
    // Idempotent; ignored when either id does not exist. A self edge is allowed.
    void   Connect(NodeID, NodeID);

    bool                HasCycle() const;
    // Every node once; among nodes that are ready together the smaller id goes first.
    // Nodes on a cycle are still returned (the smallest unplaced id is forced when
    // nothing is ready).
    std::vector<NodeID> TopologicalOrder() const;

    // Writes a Graphviz digraph to the path; does nothing when it cannot be opened.
    void ToGraphviz(std::string_view) const;

private:
    std::vector<std::unique_ptr<Node>> m_nodes;
    std::vector<std::vector<NodeID>>   m_out;
    std::vector<std::vector<NodeID>>   m_in;
    size_t                             m_edge_count { 0 };
};
} // namespace rg
} // namespace wallpaper
