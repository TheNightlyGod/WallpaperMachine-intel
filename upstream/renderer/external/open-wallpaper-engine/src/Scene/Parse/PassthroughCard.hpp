#pragma once

#include "Scene/include/Scene/SceneMesh.h"
#include "SpecTexs.hpp"

#include <Eigen/Dense>

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <utility>

namespace wallpaper
{

/// The card of a pass-through layer drawn through effects: the layer's own quad,
/// textured with the part of the screen `transform` (where the layer is drawn)
/// puts it over.
inline SceneVertexArray PassthroughCardVertices(const std::array<uint16_t, 2> size,
                                                const Eigen::Matrix4d&        transform,
                                                int32_t projection_width, int32_t projection_height) {
    float left   = -(size[0] / 2.0f);
    float right  = size[0] / 2.0f;
    float bottom = -(size[1] / 2.0f);
    float top    = size[1] / 2.0f;
    float z      = 0.0f;

    const float width  = std::max(1.0f, static_cast<float>(projection_width));
    const float height = std::max(1.0f, static_cast<float>(projection_height));

    const auto tex_coord_for = [&](float x, float y) {
        const auto world = transform * Eigen::Vector4d(x, y, 0.0, 1.0);
        return std::array<float, 2> {
            static_cast<float>(world.x()) / width,
            1.0f - (static_cast<float>(world.y()) / height),
        };
    };

    const auto bottom_left  = tex_coord_for(left, bottom);
    const auto top_left     = tex_coord_for(left, top);
    const auto bottom_right = tex_coord_for(right, bottom);
    const auto top_right    = tex_coord_for(right, top);

    const std::array pos = {
        left, bottom, z, left, top, z, right, bottom, z, right, top, z,
    };
    const std::array texCoord = {
        bottom_left[0],  bottom_left[1],  top_left[0],  top_left[1],
        bottom_right[0], bottom_right[1], top_right[0], top_right[1],
    };

    SceneVertexArray vertex(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(WE_IN_POSITION, pos);
    vertex.SetVertex(WE_IN_TEXCOORD, texCoord);
    return vertex;
}

/// The same for the `passthrough` material, whose quad is already in clip space.
inline SceneVertexArray PassthroughClipSpaceVertices(const std::array<uint16_t, 2> size,
                                                     const Eigen::Matrix4d&        transform,
                                                     int32_t                       projection_width,
                                                     int32_t projection_height) {
    float left   = -(size[0] / 2.0f);
    float right  = size[0] / 2.0f;
    float bottom = -(size[1] / 2.0f);
    float top    = size[1] / 2.0f;
    float z      = 0.0f;

    const float width  = std::max(1.0f, static_cast<float>(projection_width));
    const float height = std::max(1.0f, static_cast<float>(projection_height));

    struct VertexData {
        float clip_x;
        float clip_y;
        float u;
        float v;
    };

    const auto vertex_for = [&](float x, float y) {
        const auto  world = transform * Eigen::Vector4d(x, y, 0.0, 1.0);
        const float u     = static_cast<float>(world.x()) / width;
        const float y01   = static_cast<float>(world.y()) / height;
        return VertexData {
            .clip_x = (u * 2.0f) - 1.0f,
            .clip_y = (y01 * 2.0f) - 1.0f,
            .u      = u,
            .v      = 1.0f - y01,
        };
    };

    const auto bottom_left  = vertex_for(left, bottom);
    const auto top_left     = vertex_for(left, top);
    const auto bottom_right = vertex_for(right, bottom);
    const auto top_right    = vertex_for(right, top);

    const std::array pos = {
        bottom_left.clip_x,  bottom_left.clip_y,  z, top_left.clip_x,  top_left.clip_y,  z,
        bottom_right.clip_x, bottom_right.clip_y, z, top_right.clip_x, top_right.clip_y, z,
    };
    const std::array texCoord = {
        bottom_left.u,  bottom_left.v,  top_left.u,  top_left.v,
        bottom_right.u, bottom_right.v, top_right.u, top_right.v,
    };

    SceneVertexArray vertex(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(WE_IN_POSITION, pos);
    vertex.SetVertex(WE_IN_TEXCOORD, texCoord);
    return vertex;
}

/// How a pass-through layer's card is laid out. The part of the screen it copies
/// is where the layer is drawn, which its groups decide and which a property, a
/// script or a timeline can change while the scene runs, so the card remembers
/// the transform it was laid out from and is laid out again only when that
/// changes. Its mesh updates on that event (`MeshUpdate::OnEvent`), so the
/// renderers upload the new corners and do nothing in between.
struct PassthroughCard {
    std::array<uint16_t, 2> size {};
    /// The `passthrough` material's quad, which is already in clip space.
    bool                    clip_space { false };
    int32_t                 projection_width { 0 };
    int32_t                 projection_height { 0 };
    /// Where the layer was drawn when the card was last laid out.
    std::optional<Eigen::Matrix4d> laid_out_from;

    /// Lays `mesh` out for a layer drawn at `transform`; false, and nothing
    /// touched, when it already is.
    bool LayOut(SceneMesh& mesh, const Eigen::Matrix4d& transform) {
        if (laid_out_from.has_value() && (laid_out_from->array() == transform.array()).all()) {
            return false;
        }
        auto vertices =
            clip_space
                ? PassthroughClipSpaceVertices(size, transform, projection_width, projection_height)
                : PassthroughCardVertices(size, transform, projection_width, projection_height);
        if (mesh.VertexCount() == 0) {
            mesh.AddVertexArray(std::move(vertices));
        } else {
            mesh.GetVertexArray(0) = std::move(vertices);
        }
        mesh.SetDirty();
        laid_out_from = transform;
        return true;
    }
};

} // namespace wallpaper
