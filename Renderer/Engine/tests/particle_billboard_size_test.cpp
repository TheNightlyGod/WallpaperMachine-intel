// How big a sprite particle ends up on screen. The generator writes the authored half-size
// and nothing else; the layer's matrix scales a billboard when it is drawn, except for a
// world-space system, which is drawn through its layer's origin alone.
//
// CPU only: the generator and the subsystem step run without a renderer.

#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Scene/SpecTexs.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <span>
#include <string>
#include <vector>

using namespace wallpaper;

namespace
{

// A one-quad sprite mesh in the layout the generator writes: four vec4-aligned attributes,
// sixteen floats per vertex.
std::shared_ptr<SceneMesh> NewSpriteMesh(std::size_t quads) {
    using Attribute = SceneVertexArray::SceneVertexAttribute;
    const std::vector<Attribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORDVEC4), VertexType::FLOAT4 },
        { std::string(WE_IN_COLOR), VertexType::FLOAT4 },
        { std::string(WE_IN_TEXCOORDC2), VertexType::FLOAT2 },
    };
    auto mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    mesh->AddVertexArray(SceneVertexArray(attributes, quads * 4));
    mesh->AddIndexArray(SceneIndexArray(quads));
    return mesh;
}

// Emits one particle of the given size the first time it is asked and then leaves the
// population alone, so each Emitt() re-draws the same particle.
ParticleEmittOp OneParticleOfSize(float size) {
    return [size](std::vector<Particle>& slots, std::vector<ParticleInitOp>&, uint32_t, double,
                  std::span<const ParticleControlpoint>) {
        if (! slots.empty()) return;
        Particle p;
        ParticleModify::InitLifetime(p, 10.0f);
        ParticleModify::InitSize(p, size);
        slots.push_back(p);
    };
}

// One sprite layer: a scene, a particle system with the production generator, one subsystem
// and the node that carries the layer.
struct SpriteLayer {
    Scene                      scene;
    ParticleSystem             system { scene };
    std::shared_ptr<SceneMesh> mesh { NewSpriteMesh(1) };
    std::shared_ptr<SceneNode> owner { std::make_shared<SceneNode>() };
    ParticleSubSystem*         subsystem { nullptr };

    explicit SpriteLayer(float particle_size, bool world_space = false) {
        scene.frameTime = 0.1;
        system.gener    = std::make_unique<WPParticleRawGener>();
        auto made = std::make_unique<ParticleSubSystem>(
            system, mesh, 8, 1.0, 1, 1.0, ParticleSubSystem::SpawnType::STATIC,
            [](const Particle&, const ParticleRawGenSpec&) {});
        subsystem = made.get();
        subsystem->SetOwnerNode(owner);
        subsystem->SetWorldSpace(world_space);
        subsystem->AddEmitter(OneParticleOfSize(particle_size));
        system.subsystems.push_back(std::move(made));
    }

    // Float offsets of the attributes the checks read.
    std::size_t Offset(std::string_view name) const {
        const auto map = mesh->GetVertexArray(0).GetAttrOffsetMap();
        return map.at(std::string(name)).offset / sizeof(float);
    }

    const float* Vertex(std::size_t index) const {
        const auto& array = mesh->GetVertexArray(0);
        return array.Data() + index * array.OneSize();
    }

    // The half-size the generator wrote for the quad's first vertex.
    float HalfSize() const { return Vertex(0)[Offset(WE_IN_TEXCOORDVEC4) + 3]; }

    // The width and height, in normalized device coordinates, of the billboard as the camera
    // sees it through the layer's draw matrix.
    std::array<double, 2> ProjectedExtent(const SceneCamera& camera) {
        owner->UpdateTrans();
        const linalg::Matrix4d to_clip = camera.GetViewProjectionMatrix() * owner->RenderTrans();
        std::array<double, 2> low { 1e300, 1e300 }, high { -1e300, -1e300 };
        for (std::size_t v = 0; v < 4; ++v) {
            const float* vertex = Vertex(v);
            const float* at     = vertex + Offset(WE_IN_POSITION);
            const float* corner = vertex + Offset(WE_IN_TEXCOORDVEC4);
            const double half   = corner[3];
            const linalg::Vector4d point(at[0] + (corner[0] * 2.0 - 1.0) * half,
                                         at[1] + (corner[1] * 2.0 - 1.0) * half, at[2], 1.0);
            const linalg::Vector4d clip = to_clip * point;
            EXPECT_GT(clip.w(), 0.0) << "the billboard must be in front of the camera";
            for (int axis = 0; axis < 2; ++axis) {
                const double ndc = clip[axis] / clip.w();
                low[axis]        = std::min(low[axis], ndc);
                high[axis]       = std::max(high[axis], ndc);
            }
        }
        return { high[0] - low[0], high[1] - low[1] };
    }
};

SceneCamera Orthographic() { return SceneCamera(100, 100, 0.1f, 100.0f); }
SceneCamera Perspective() { return SceneCamera(1.0f, 0.1f, 100.0f, 90.0f); }

constexpr double kTolerance = 1e-6;

} // namespace

// PB-01
TEST(ParticleBillboardSize, LayerSpaceBillboardIsDrawnThroughTheWholeLayerMatrix) {
    for (const bool display_sized : { false, true }) {
        SCOPED_TRACE(testing::Message() << "display_sized " << display_sized);
        SpriteLayer layer(2.0f);
        layer.scene.display_sized = display_sized;
        const SceneCamera camera  = Perspective();
        layer.owner->SetTranslate({ 0.0f, 0.0f, -10.0f });

        const auto expect_extent = [&](double x, double y, const char* what) {
            layer.subsystem->Emitt();
            const auto extent = layer.ProjectedExtent(camera);
            EXPECT_NEAR(extent[0], x, kTolerance) << what << " (width)";
            EXPECT_NEAR(extent[1], y, kTolerance) << what << " (height)";
        };

        layer.owner->SetScale({ 0.25f, 0.25f, 0.25f });
        expect_extent(0.05, 0.05, "scale 0.25");
        layer.owner->SetScale({ 0.75f, 0.75f, 0.75f });
        expect_extent(0.15, 0.15, "scale 0.75");
        layer.owner->SetScale({ 1.0f, 1.0f, 1.0f });
        expect_extent(0.2, 0.2, "unit scale at 10 units");

        layer.owner->SetTranslate({ 0.0f, 0.0f, -20.0f });
        expect_extent(0.1, 0.1, "twice as far");

        // A scaled parent multiplies in; a negative factor only mirrors.
        auto parent = std::make_shared<SceneNode>();
        parent->SetScale({ 2.0f, 3.0f, 1.0f });
        parent->AppendChild(layer.owner);
        layer.owner->SetScale({ -0.5f, 0.5f, 1.0f });
        expect_extent(0.1, 0.15, "scaled and mirrored through a parent");
    }
}

// PB-02
TEST(ParticleBillboardSize, AuthoredCanvasAndPerspectiveCamerasBothFollowTheLayerScale) {
    SpriteLayer layer(2.0f);
    layer.owner->SetTranslate({ 0.0f, 0.0f, -10.0f });
    const SceneCamera ortho = Orthographic();
    const SceneCamera persp = Perspective();

    for (const float s : { 0.25f, 0.75f, -1.5f }) {
        SCOPED_TRACE(testing::Message() << "layer scale " << s);
        layer.owner->SetScale({ s, s, 1.0f });
        layer.subsystem->Emitt();

        const auto flat = layer.ProjectedExtent(ortho);
        EXPECT_NEAR(flat[0], 0.04 * std::abs(s), kTolerance) << "orthographic width";
        EXPECT_NEAR(flat[1], 0.04 * std::abs(s), kTolerance) << "orthographic height";

        const auto deep = layer.ProjectedExtent(persp);
        EXPECT_NEAR(deep[0], 0.2 * std::abs(s), kTolerance) << "perspective width";
        EXPECT_NEAR(deep[1], 0.2 * std::abs(s), kTolerance) << "perspective height";
    }
}

// PB-03
TEST(ParticleBillboardSize, WorldSpaceBillboardKeepsItsAuthoredSizeWhateverTheLayerDoes) {
    SpriteLayer layer(2.0f, /*world_space=*/true);
    const SceneCamera ortho = Orthographic();
    layer.owner->SetTranslate({ 0.0f, 0.0f, -10.0f });

    const std::array<linalg::Vector3f, 3> scales {
        linalg::Vector3f { 0.25f, 0.25f, 1.0f },
        linalg::Vector3f { 24.0f, 1.0f, 1.05f },
        linalg::Vector3f { -1.5f, 3.0f, 1.0f },
    };
    for (const auto& scale : scales) {
        SCOPED_TRACE(testing::Message()
                     << "layer scale (" << scale.x() << ", " << scale.y() << ", " << scale.z() << ")");
        layer.owner->SetScale(scale);
        layer.owner->SetRotation({ 0.0f, 0.0f, 0.4f });
        layer.subsystem->Emitt();

        const auto extent = layer.ProjectedExtent(ortho);
        EXPECT_NEAR(extent[0], 0.04, kTolerance);
        EXPECT_NEAR(extent[1], 0.04, kTolerance);

        const linalg::Matrix4d draw = layer.owner->RenderTrans();
        for (int row = 0; row < 3; ++row) {
            for (int col = 0; col < 3; ++col) {
                EXPECT_NEAR(draw(row, col), row == col ? 1.0 : 0.0, 1e-12)
                    << "draw matrix carries no rotation or scale at (" << row << ", " << col << ")";
            }
        }
        EXPECT_NEAR(draw(2, 3), -10.0, 1e-9) << "the layer's origin still places the system";
    }

    // Moving the layer moves where the system is drawn.
    layer.owner->SetTranslate({ 30.0f, 20.0f, -10.0f });
    layer.subsystem->Emitt();
    const linalg::Matrix4d moved = layer.owner->RenderTrans();
    EXPECT_NEAR(moved(0, 3), 30.0, 1e-9);
    EXPECT_NEAR(moved(1, 3), 20.0, 1e-9);
    EXPECT_NEAR(moved(2, 3), -10.0, 1e-9);
}

// PB-04
TEST(ParticleBillboardSize, GeneratorWritesTheAuthoredHalfSizeWhateverTheOwnerAndParentScales) {
    struct Case {
        linalg::Vector3f parent_scale;
        linalg::Vector3f owner_scale;
        float            owner_turn;
    };
    const Case cases[] = {
        { { 1.0f, 1.0f, 1.0f }, { 2.0f, 2.0f, 1.0f }, 0.0f },
        { { 1.0f, 1.0f, 1.0f }, { -6.0f, -6.0f, 1.0f }, 0.0f },
        { { 1.0f, 1.0f, 1.0f }, { 2.0f, 6.0f, 1.0f }, 0.5f },
        { { 2.0f, 3.0f, 1.0f }, { 4.0f, 2.0f, 1.0f }, 0.0f },
    };
    for (const Case& c : cases) {
        SCOPED_TRACE(testing::Message() << "owner scale (" << c.owner_scale.x() << ", "
                                        << c.owner_scale.y() << "), parent scale ("
                                        << c.parent_scale.x() << ", " << c.parent_scale.y()
                                        << "), turn " << c.owner_turn);
        SpriteLayer layer(48.0f);
        layer.scene.frameTime = 1.0;
        auto parent           = std::make_shared<SceneNode>();
        parent->SetScale(c.parent_scale);
        parent->AppendChild(layer.owner);
        layer.owner->SetScale(c.owner_scale);
        layer.owner->SetRotation({ 0.0f, 0.0f, c.owner_turn });

        layer.subsystem->Emitt();
        EXPECT_EQ(layer.HalfSize(), 24.0f);
    }
}
