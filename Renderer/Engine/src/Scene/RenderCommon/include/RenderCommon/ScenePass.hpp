#pragma once

#include "Interface/IShaderValueUpdater.h"
#include "RenderGraph/Pass.hpp"
#include "SpecTexs.hpp"
#include "SpriteAnimation.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

class SceneNode;

namespace rg
{

/// A step of the render graph, as the scene describes it and no backend does:
/// the targets it reads and writes, the node and submesh it draws, and how it
/// loads its target. Each class holds one description and nothing else, so a
/// backend that executes the graph reads the steps here and keeps its own
/// per-step state next to its own code. `sceneToRenderGraph` builds the graph
/// out of these, and the renderer reads them as they are.
///
/// The classes are defined out of line (ScenePass.cpp) so that each one's
/// vtable and typeinfo are emitted by one translation unit: a renderer finds a
/// step's kind with `dynamic_cast`, and that compares type information, which
/// two static archives must not each carry a copy of.

/// Clears a target, to the scene's background or to nothing.
class ClearPass : public Pass {
public:
    struct Desc {
        std::string result { SpecTex_Default };
        bool        transparent { false };
    };

    explicit ClearPass(const Desc&);
    ~ClearPass() override;

    const Desc& desc() const { return m_desc; }
    Desc&       desc() { return m_desc; }

private:
    Desc m_desc;
};

/// Copies one target into another.
class CopyPass : public Pass {
public:
    struct Desc {
        std::string src;
        std::string dst;
    };

    explicit CopyPass(const Desc&);
    ~CopyPass() override;

    const Desc& desc() const { return m_desc; }
    Desc&       desc() { return m_desc; }

private:
    Desc m_desc;
};

/// Draws one submesh of a node with one of its materials.
class DrawPass : public Pass {
public:
    struct Desc {
        SceneNode*               node { nullptr };
        /// The node whose visibility decides whether the draw happens; the
        /// layer an effect or compose step belongs to rather than the step's
        /// own node.
        SceneNode*               visibility_node { nullptr };
        /// Indexed by material texture slot; an empty name leaves the slot unbound.
        std::vector<std::string> textures;
        std::string              output;           // render target the draw writes to
        std::string              camera_override;  // draw through this camera instead of the node's
        std::size_t              submesh_index { 0 };
        uint32_t                 material_slot { 0 };
        /// Target handling: wipe it on first use, or keep what it already holds.
        bool                     clear_on_first_use { false };
        bool                     preserve_target_contents { false };
        /// Alpha is written unless a draw turns it off.
        bool                     write_alpha { true };
        /// The draw replaces what the target holds instead of blending with it,
        /// whatever blending its material asks for: a layer's own composite keeps
        /// the colour and alpha its effect chain wrote.
        bool                     replace_target { false };
        /// The samples per pixel the target asks for (1, 2, 4, 8, 16, 32 or 64).
        /// What a backend can give is its own decision.
        uint32_t                 samples { 1 };
        sprite_map_t             sprites_map;
    };

    explicit DrawPass(const Desc&);
    ~DrawPass() override;

    const Desc& desc() const { return m_desc; }
    Desc&       desc() { return m_desc; }

    /// Points texture slot `index` at another target; the graph builder uses it
    /// to bind a layer's link texture once the copy that fills it exists.
    void setDescTex(uint32_t index, std::string_view tex_key);

private:
    Desc m_desc;
};

/// The sample count a target's request means: powers of two up to 64, and one
/// for anything else.
[[nodiscard]] uint32_t NormalizeSampleCount(uint32_t requested);

} // namespace rg
} // namespace wallpaper
