// Helpers local to the scene-schema behaviour tests of part 2 (canvas shots, lights, fog, texel,
// shake, normals, hidden-layer retention and camera nodes). Header-only; builds on
// schema_fixtures.hpp and adds nothing to its API.
#pragma once

#include "support/schema_fixtures.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneShader.h"
#include "Scene/SceneUpdateDemand.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <initializer_list>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace we_schema::p2
{

using wallpaper::Scene;
using wallpaper::SceneCamera;
using wallpaper::SceneNode;

constexpr std::uint32_t kAnimationDemand = static_cast<std::uint32_t>(wallpaper::SceneDemandReason::Animation);

// ---- where a canvas point lands on screen ------------------------------------------------

/// Normalised device coordinates of the canvas point (x, y, 0) as `camera` projects it.
inline std::array<double, 2> Ndc(const SceneCamera& camera, double x, double y)
{
    const auto clip = camera.GetViewProjectionMatrix() * wallpaper::linalg::Vector4d(x, y, 0.0, 1.0);
    return { clip.x() / clip.w(), clip.y() / clip.w() };
}

/// The view of a 640x360 canvas is centred on canvas point `centre` and shows 1/zoom of the
/// canvas: the centre maps to the middle of the screen and the point half a view up and to the
/// right maps to the top right corner. Checked on both the orthographic camera the scene draws
/// through and the perspective one layers with the `perspective` flag draw through.
inline void ExpectViewFrame(Scene& scene, double centre_x, double centre_y, double zoom, double tolerance = 1e-4)
{
    const auto check = [&](const SceneCamera* camera, const char* which) {
        ASSERT_NE(camera, nullptr) << which;
        const auto middle = Ndc(*camera, centre_x, centre_y);
        EXPECT_NEAR(middle[0], 0.0, tolerance) << which << " centre x";
        EXPECT_NEAR(middle[1], 0.0, tolerance) << which << " centre y";
        const auto corner = Ndc(*camera, centre_x + 320.0 / zoom, centre_y + 180.0 / zoom);
        EXPECT_NEAR(corner[0], 1.0, tolerance) << which << " corner x";
        EXPECT_NEAR(corner[1], 1.0, tolerance) << which << " corner y";
    };
    ASSERT_NE(scene.activeCamera, nullptr);
    EXPECT_FALSE(scene.activeCamera->IsPerspective());
    check(scene.activeCamera, "active camera");
    const auto lens = scene.cameras.find("global_perspective");
    ASSERT_NE(lens, scene.cameras.end());
    EXPECT_TRUE(lens->second->IsPerspective());
    check(lens->second.get(), "global_perspective");
}

// ---- reading the shader constants a draw would receive -----------------------------------

/// Every constant written by one `UpdateUniforms`, name to lanes (the last write of a name wins).
using Recorded = std::map<std::string, std::vector<float>>;

/// Asks the scene's updater for `wanted` on slot `slot` of `node` and records what it writes. The
/// "does the shader declare it" answer is the probe's own: true exactly for the wanted names.
inline Recorded Probe(Scene& scene, SceneNode& node, std::initializer_list<std::string_view> wanted, std::uint32_t slot = 0)
{
    std::set<std::string, std::less<>> names;
    for (const auto name : wanted) names.emplace(name);
    auto* updater = scene.shaderValueUpdater.get();
    Recorded out;
    if (updater == nullptr) return out;
    updater->InitUniforms(&node, slot, [&](std::string_view name) { return names.find(name) != names.end(); });
    wallpaper::sprite_map_t sprites;
    updater->UpdateUniforms(&node, slot, sprites, [&](std::string_view name, const wallpaper::ShaderValue& value) {
        out[std::string(name)].assign(value.data(), value.data() + value.size());
    });
    return out;
}

/// The four lanes of array element `slot` of recorded constant `name` are `expected`.
inline ::testing::AssertionResult SlotIs(const Recorded& recorded, const std::string& name, std::size_t slot,
                                          const std::array<float, 4>& expected, float tolerance = 1e-4f)
{
    const auto found = recorded.find(name);
    if (found == recorded.end()) return ::testing::AssertionFailure() << name << " was never written";
    const auto& lanes = found->second;
    if (lanes.size() < 4 * slot + 4)
        return ::testing::AssertionFailure() << name << " has " << lanes.size() << " lanes, slot " << slot << " needs " << 4 * slot + 4;
    for (std::size_t i = 0; i < 4; ++i) {
        if (!(std::abs(lanes[4 * slot + i] - expected[i]) <= tolerance))
            return ::testing::AssertionFailure() << name << "[" << slot << "] lane " << i << " is " << lanes[4 * slot + i]
                                                 << ", expected " << expected[i];
    }
    return ::testing::AssertionSuccess();
}

// ---- documents ---------------------------------------------------------------------------

/// A model layer of the leaf model assets (`planet.mdl`).
inline Json ModelObject(int id, const std::string& name, const Json& extra = Json::object())
{
    Json object = { { "id", id }, { "name", name }, { "model", "planet.mdl" }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) object[key] = value;
    return object;
}

/// A light layer. `kind` is the `light` string.
inline Json LightObject(int id, const std::string& name, const std::string& kind, const Json& extra = Json::object())
{
    Json object = { { "id", id }, { "name", name }, { "light", kind }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) object[key] = value;
    return object;
}

} // namespace we_schema::p2
