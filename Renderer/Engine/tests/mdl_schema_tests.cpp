#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "Scene/SceneMesh.h"
#include "WPMdlParser.hpp"

namespace
{
using namespace wallpaper;
} // namespace

TEST(MdlSchema, GenMeshIncludesNormals) {
    WPMdl::Mesh src;
    src.positions = { { 0.0f, 0.0f, 0.0f }, { 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f } };
    src.normals   = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    src.tangents  = { { 1.0f, 0.0f, 0.0f, 1.0f },
                      { 1.0f, 0.0f, 0.0f, 1.0f },
                      { 1.0f, 0.0f, 0.0f, 1.0f } };
    src.texcoords = { { 0.0f, 0.0f }, { 1.0f, 0.0f }, { 0.0f, 1.0f } };
    src.indices   = { { 0, 1, 2 } };

    SceneMesh::Submesh submesh;
    WPMdlParser::GenMeshFromMdl(submesh, src);
    ASSERT_EQ(submesh.VertexCount(), 1u);
    const auto& attributes = submesh.GetVertexArray(0).Attributes();
    bool        has_normal  = false;
    bool        has_tangent = false;
    for (const auto& attribute : attributes) {
        if (attribute.name == "a_Normal") has_normal = true;
        // The name Wallpaper Engine's model shaders declare for it
        // (`attribute vec4 a_Tangent4`); a mesh that names it otherwise leaves
        // the shader's input unbound.
        if (attribute.name == "a_Tangent4") has_tangent = true;
    }
    EXPECT_TRUE(has_normal);
    EXPECT_TRUE(has_tangent);
}

TEST(MdlSchema, MirrorFrameMappingWrapsAtThePeriodEvenWhenTheDivisionRoundsUp) {
    auto make = [](double fps, i32 length) {
        auto puppet = std::make_shared<WPPuppet>();
        WPPuppet::Animation anim;
        anim.id = 1;
        anim.fps = fps;
        anim.length = length;
        anim.mode = WPPuppet::PlayMode::Mirror;
        puppet->anims.push_back(std::move(anim));
        puppet->prepared();
        return puppet;
    };
    // Four frames at four per second: v = 5.5 plays samples 3 then 2.
    auto   plain = make(4.0, 4);
    double time  = 5.5 / 4.0;
    auto   info  = plain->anims[0].getInterpolationInfo(&time);
    EXPECT_EQ(info.frame_a, 3);
    EXPECT_EQ(info.frame_b, 2);
    EXPECT_NEAR(info.t, 0.5, 1.0e-9);

    // A time one step below the period of a three-frame animation at three per second divides
    // up to exactly 2L frames; that is the wrap, so the fraction must stay inside 0..1.
    auto   rounded = make(3.0, 3);
    double period  = 2.0 * rounded->anims[0].max_time;
    time           = std::nextafter(period, 0.0);
    info           = rounded->anims[0].getInterpolationInfo(&time);
    EXPECT_EQ(info.frame_a, 0);
    EXPECT_EQ(info.frame_b, 1);
    EXPECT_GE(info.t, 0.0);
    EXPECT_LE(info.t, 1.0);
}
