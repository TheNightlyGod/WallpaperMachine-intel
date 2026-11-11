// The ribbons the particle generator draws. A rope threads the live particles of one instance
// in slot order; a rope trail draws, for each particle, a ribbon back along its own recorded
// path. Each ribbon is written as pieces, one quad per piece, whose vertex data tells the
// shader where the piece starts and ends, how long the strip is and which piece this is.
// The tests also cover the texture-repeat encoding and the rebuild of a hidden layer's
// geometry on the frame it is revealed.
//
// CPU only: the generator and the subsystem step run without a renderer.

#include "Interface/IParticleRawGener.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/ParticleTrail.h"
#include "Particle/WPParticleRawGener.h"
#include "Scene/Scene.h"
#include "Scene/SceneIndexArray.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Scene/SceneVertexArray.h"
#include "Scene/SpecTexs.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <initializer_list>
#include <memory>
#include <span>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

using namespace wallpaper;

namespace
{

constexpr uint32_t kQuadCapacity = 16;

enum class RopeKind { Plain, Trail };

std::shared_ptr<SceneMesh> NewRopeMesh(bool thick, RopeKind kind = RopeKind::Plain) {
    using Attribute = SceneVertexArray::SceneVertexAttribute;
    std::vector<Attribute> attributes;
    const auto add = [&](std::string_view name) {
        attributes.push_back({ std::string(name), VertexType::FLOAT4 });
    };
    add(WE_IN_POSITIONVEC4);
    add(WE_IN_TEXCOORDVEC4);
    add(WE_IN_TEXCOORDVEC4C1);
    if (thick) {
        add(WE_IN_TEXCOORDVEC4C2);
        add(WE_IN_TEXCOORDVEC4C3);
        add(WE_IN_TEXCOORDC4);
    } else {
        add(WE_IN_TEXCOORDVEC3C2);
        add(WE_IN_TEXCOORDC3);
    }
    add(WE_IN_COLOR);

    auto mesh   = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    const auto layout = PlanParticleIndexLayout(kQuadCapacity);
    SceneVertexArray vertices(attributes, kQuadCapacity * 4);
    vertices.SetOption(WE_PRENDER_ROPE, true);
    vertices.SetOption(WE_CB_THICK_FORMAT, thick);
    if (kind == RopeKind::Trail) {
        vertices.SetOption(WE_PRENDER_TRAIL, true);
        vertices.SetOption(WE_PRENDER_ROPETRAIL, true);
    }
    mesh->AddVertexArray(std::move(vertices));
    mesh->AddIndexArray(SceneIndexArray(kQuadCapacity, layout.width));
    return mesh;
}

using Point = std::array<float, 3>;

Particle LiveAt(Point at, float size = 20.0f) {
    Particle p;
    p.position = { at[0], at[1], at[2] };
    p.size     = size;
    p.lifetime = 1.0f;
    return p;
}

Particle DeadAt(Point at) {
    Particle p = LiveAt(at);
    p.lifetime = 0.0f;
    return p;
}

std::unique_ptr<ParticleInstance> InstanceOf(std::initializer_list<Particle> particles) {
    auto instance = std::make_unique<ParticleInstance>();
    for (const Particle& p : particles) instance->ParticlesVec().push_back(p);
    return instance;
}

ParticleTrailSample SampleAt(Point at) {
    ParticleTrailSample sample;
    sample.position = linalg::Vector3f(at[0], at[1], at[2]);
    return sample;
}

// Gives each slot a recorded path, oldest point first, in a history of the given capacity.
void Record(ParticleInstance& instance, std::size_t slot, uint32_t capacity,
            std::initializer_list<Point> oldest_first) {
    auto& trails = instance.TrailsVec();
    if (trails.size() <= slot) trails.resize(slot + 1);
    trails[slot].Reset(capacity);
    for (const Point& at : oldest_first) trails[slot].Push(SampleAt(at));
}

using Instances = std::vector<std::unique_ptr<ParticleInstance>>;

Instances Single(std::unique_ptr<ParticleInstance> instance) {
    Instances all;
    all.push_back(std::move(instance));
    return all;
}

void Generate(const Instances& instances, SceneMesh& mesh, ParticleRenderScale scale = {}) {
    WPParticleRawGener     generator;
    ParticleRawGenSpecOp   spec = [](const Particle&, const ParticleRawGenSpec&) {};
    ParticleOverflowFlags  flags;
    generator.GenGLData(instances, mesh, spec, scale, flags);
}

// One quad of the generated mesh, read as the record of a piece.
class Quad {
public:
    Quad(const SceneMesh& mesh, std::size_t index) : m_mesh(mesh), m_index(index) {}

    // Float `i` of the piece record, read from vertex `vertex` of the quad.
    float f(std::size_t i, std::size_t vertex = 0) const {
        const auto& vertices = m_mesh.GetVertexArray(0);
        return vertices.Data()[(m_index * 4 + vertex) * vertices.OneSize() + i];
    }
    std::array<float, 3> start() const { return { f(0), f(1), f(2) }; }
    std::array<float, 3> end() const { return { f(4), f(5), f(6) }; }
    float start_half_size() const { return f(3); }
    float length() const { return f(7); }
    float along() const { return f(11); }
    float end_half_size() const { return f(15); }

private:
    const SceneMesh& m_mesh;
    std::size_t      m_index;
};

std::size_t Pieces(const SceneMesh& mesh) { return mesh.GetIndexArray(0).RenderDataCount() / 3; }

::testing::AssertionResult SamePoint(const std::array<float, 3>& got, Point want, float tolerance = 0) {
    for (int i = 0; i < 3; ++i) {
        if (std::abs(got[i] - want[i]) > tolerance) {
            return ::testing::AssertionFailure()
                   << "(" << got[0] << ", " << got[1] << ", " << got[2] << ") is not (" << want[0]
                   << ", " << want[1] << ", " << want[2] << ")";
        }
    }
    return ::testing::AssertionSuccess();
}

// How the rope's vertex shader maps a piece (`p` along the strip, encoded length `L`) and a
// position `y` across the piece (0 start, 1 end) to the texture coordinate along the rope.
double TextureV(double p, double L, double y) { return 1.0 - (p + y) / (L - 1.0); }

// How many times the texture repeats from the first piece's start to the last piece's end.
double RepeatSpan(const SceneMesh& mesh) {
    const Quad   first(mesh, 0);
    const Quad   last(mesh, Pieces(mesh) - 1);
    return TextureV(first.along(), first.length(), 0.0) - TextureV(last.along(), last.length(), 1.0);
}

Instances ThreeInALine() {
    return Single(InstanceOf({ LiveAt({ 0, 0, 0 }), LiveAt({ 10, 0, 0 }), LiveAt({ 20, 0, 0 }) }));
}

constexpr std::array<std::array<float, 2>, 4> kCornerOrder { { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } } };

} // namespace

// RG-01
TEST(RopePieces, ThreeParticlesAtSubdivisionOneMakeTwoPiecesThroughConsecutivePairs) {
    auto mesh      = NewRopeMesh(/*thick=*/false);
    auto instances = ThreeInALine();
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 6u);
    EXPECT_EQ(mesh->GetIndexArray(0).DrawIndexCount(), 12u);
    ASSERT_EQ(Pieces(*mesh), 2u);

    const Quad a(*mesh, 0), b(*mesh, 1);
    EXPECT_TRUE(SamePoint(a.start(), { 0, 0, 0 }));
    EXPECT_TRUE(SamePoint(a.end(), { 10, 0, 0 }));
    EXPECT_EQ(a.length(), 3.0f);
    EXPECT_EQ(a.along(), 0.0f);
    EXPECT_EQ(a.start_half_size(), 10.0f);
    EXPECT_EQ(a.end_half_size(), 10.0f);
    EXPECT_TRUE(SamePoint(b.start(), { 10, 0, 0 }));
    EXPECT_TRUE(SamePoint(b.end(), { 20, 0, 0 }));
    EXPECT_EQ(b.length(), 3.0f);
    EXPECT_EQ(b.along(), 1.0f);

    // Corners of the quad's four vertices, and everything else identical across them.
    for (std::size_t v = 0; v < 4; ++v) {
        EXPECT_EQ(a.f(16, v), kCornerOrder[v][0]) << "vertex " << v;
        EXPECT_EQ(a.f(17, v), kCornerOrder[v][1]) << "vertex " << v;
        for (std::size_t i = 0; i < 16; ++i) EXPECT_EQ(a.f(i, v), a.f(i, 0)) << "float " << i;
    }

    // Two triangles per quad over that quad's four vertices.
    const auto* indices = reinterpret_cast<const uint16_t*>(mesh->GetIndexArray(0).Data());
    for (uint16_t quad = 0; quad < 2; ++quad) {
        const uint16_t base = quad * 4;
        const uint16_t want[6] = { base, uint16_t(base + 1), uint16_t(base + 3),
                                   uint16_t(base + 1), uint16_t(base + 2), uint16_t(base + 3) };
        for (int i = 0; i < 6; ++i) EXPECT_EQ(indices[quad * 6 + i], want[i]) << "quad " << quad;
    }
}

// RG-02
TEST(RopePieces, ADeadParticleBetweenLiveOnesIsSkippedAndItsNeighboursJoined) {
    auto mesh      = NewRopeMesh(false);
    auto instances = Single(InstanceOf({ LiveAt({ 0, 0, 0 }), DeadAt({ 100, 0, 0 }), LiveAt({ 20, 0, 0 }) }));
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 3u);
    ASSERT_EQ(Pieces(*mesh), 1u);
    const Quad q(*mesh, 0);
    EXPECT_TRUE(SamePoint(q.start(), { 0, 0, 0 }));
    EXPECT_TRUE(SamePoint(q.end(), { 20, 0, 0 }));
    EXPECT_EQ(q.length(), 2.0f);
    EXPECT_EQ(q.along(), 0.0f);
}

// RG-03
TEST(RopePieces, PiecesNeverSpanTwoInstances) {
    auto mesh = NewRopeMesh(false);
    Instances instances;
    instances.push_back(InstanceOf({ LiveAt({ 0, 0, 0 }), LiveAt({ 1, 0, 0 }) }));
    instances.push_back(InstanceOf({ LiveAt({ 10, 0, 0 }), LiveAt({ 11, 0, 0 }) }));
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 6u);
    ASSERT_EQ(Pieces(*mesh), 2u);
    const Quad a(*mesh, 0), b(*mesh, 1);
    EXPECT_TRUE(SamePoint(a.start(), { 0, 0, 0 }));
    EXPECT_TRUE(SamePoint(a.end(), { 1, 0, 0 }));
    EXPECT_EQ(a.length(), 2.0f);
    EXPECT_EQ(a.along(), 0.0f);
    EXPECT_TRUE(SamePoint(b.start(), { 10, 0, 0 }));
    EXPECT_TRUE(SamePoint(b.end(), { 11, 0, 0 }));
    EXPECT_EQ(b.length(), 2.0f);
    EXPECT_EQ(b.along(), 0.0f) << "the count along the strip starts over in each instance";
}

// RG-04
TEST(RopePieces, FewerThanTwoLiveParticlesDrawNothing) {
    const auto pieces_for = [](Instances instances) {
        auto mesh = NewRopeMesh(false);
        Generate(instances, *mesh);
        return mesh->GetIndexArray(0).RenderDataCount();
    };
    EXPECT_EQ(pieces_for(Single(InstanceOf({}))), 0u) << "no particles";
    EXPECT_EQ(pieces_for(Single(InstanceOf({ LiveAt({ 1, 2, 3 }) }))), 0u) << "one particle";
    EXPECT_EQ(pieces_for(Single(InstanceOf({ LiveAt({ 1, 2, 3 }), DeadAt({ 4, 5, 6 }) }))), 0u)
        << "one live, one dead";
    EXPECT_EQ(pieces_for(Single(InstanceOf({ DeadAt({ 1, 2, 3 }), DeadAt({ 4, 5, 6 }) }))), 0u)
        << "only dead ones";
}

// RG-05
TEST(RopePieces, SubdivisionThreeSplitsTwoPairsIntoSixPiecesThroughTheMiddleStation) {
    auto mesh      = NewRopeMesh(false);
    auto instances = ThreeInALine();
    ParticleRenderScale scale;
    scale.rope_subdivision = 3;
    Generate(instances, *mesh, scale);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 18u);
    ASSERT_EQ(Pieces(*mesh), 6u);
    for (std::size_t q = 0; q < 6; ++q) {
        const Quad quad(*mesh, q);
        EXPECT_EQ(quad.length(), 7.0f) << "(3 - 1) * 3 + 1 pieces' worth of stations";
        EXPECT_EQ(quad.along(), static_cast<float>(q)) << "pieces count on across the pairs";
        if (q + 1 < 6 && q != 2) {
            const Quad next(*mesh, q + 1);
            EXPECT_TRUE(SamePoint(quad.end(), next.start(), 1e-4f))
                << "piece " << q << " ends where the next one starts";
        }
    }
    EXPECT_TRUE(SamePoint(Quad(*mesh, 0).start(), { 0, 0, 0 }));
    EXPECT_TRUE(SamePoint(Quad(*mesh, 3).start(), { 10, 0, 0 }, 1e-5f));
    EXPECT_TRUE(SamePoint(Quad(*mesh, 5).end(), { 20, 0, 0 }, 1e-5f));
}

// RG-06
TEST(RopePieces, CoincidentParticlesMakeNoPieceAndNoNaN) {
    {
        auto mesh      = NewRopeMesh(false);
        auto instances = Single(InstanceOf({ LiveAt({ 4, 5, 6 }), LiveAt({ 4, 5, 6 }) }));
        Generate(instances, *mesh);
        EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 0u);
        const auto& vertices = mesh->GetVertexArray(0);
        for (std::size_t i = 0; i < vertices.CapacitySize(); ++i)
            ASSERT_TRUE(std::isfinite(vertices.Data()[i])) << "float " << i;
    }
    {
        // The skipped pair still takes its place in the count along the strip.
        auto mesh      = NewRopeMesh(false);
        auto instances = Single(InstanceOf({ LiveAt({ 0, 0, 0 }), LiveAt({ 0, 0, 0 }), LiveAt({ 10, 0, 0 }) }));
        Generate(instances, *mesh);
        ASSERT_EQ(Pieces(*mesh), 1u);
        const Quad q(*mesh, 0);
        EXPECT_TRUE(SamePoint(q.start(), { 0, 0, 0 }));
        EXPECT_TRUE(SamePoint(q.end(), { 10, 0, 0 }));
        EXPECT_EQ(q.along(), 1.0f);
        EXPECT_EQ(q.length(), 3.0f);
    }
}

// RG-07
TEST(RopePieces, ThickFormatCarriesTheEndColourAndEndHalfSize) {
    Particle start = LiveAt({ 0, 0, 0 }, 8.0f);
    start.color    = { 1.0f, 0.0f, 0.0f };
    start.alpha    = 0.5f;
    Particle end   = LiveAt({ 10, 0, 0 }, 12.0f);
    end.color      = { 0.0f, 1.0f, 0.0f };
    end.alpha      = 0.25f;

    {
        auto mesh      = NewRopeMesh(/*thick=*/true);
        auto instances = Single(InstanceOf({ start, end }));
        Generate(instances, *mesh);
        EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 3u);
        const Quad q(*mesh, 0);
        EXPECT_EQ(q.start_half_size(), 4.0f);
        EXPECT_EQ(q.end_half_size(), 6.0f);
        EXPECT_EQ(q.f(16), 0.0f);
        EXPECT_EQ(q.f(17), 1.0f);
        EXPECT_EQ(q.f(18), 0.0f);
        EXPECT_EQ(q.f(19), 0.25f);
        EXPECT_EQ(q.f(24), 1.0f);
        EXPECT_EQ(q.f(25), 0.0f);
        EXPECT_EQ(q.f(26), 0.0f);
        EXPECT_EQ(q.f(27), 0.5f);
    }
    {
        auto mesh      = NewRopeMesh(/*thick=*/false);
        auto instances = Single(InstanceOf({ start, end }));
        Generate(instances, *mesh);
        const Quad q(*mesh, 0);
        EXPECT_EQ(q.start_half_size(), 4.0f);
        EXPECT_EQ(q.end_half_size(), 6.0f);
        EXPECT_EQ(q.f(20), 1.0f);
        EXPECT_EQ(q.f(21), 0.0f);
        EXPECT_EQ(q.f(22), 0.0f);
        EXPECT_EQ(q.f(23), 0.5f);
    }
}

// RG-08
TEST(RopePieces, AnInstancesBoundedOffsetIsAddedToBothEndsOfARope) {
    auto instance = InstanceOf({ LiveAt({ 1, 2, 3 }), LiveAt({ 4, 5, 6 }) });
    instance->GetBoundedData().pos = { 100.0f, 200.0f, 300.0f };
    auto mesh      = NewRopeMesh(false);
    auto instances = Single(std::move(instance));
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 3u);
    const Quad q(*mesh, 0);
    EXPECT_TRUE(SamePoint(q.start(), { 101, 202, 303 }));
    EXPECT_TRUE(SamePoint(q.end(), { 104, 205, 306 }));
    EXPECT_EQ(q.length(), 2.0f);
    EXPECT_EQ(q.along(), 0.0f);
}

// RG-09
TEST(RopePieces, ATrailRunsFromTheCurrentPositionBackThroughTheRecordedPoints) {
    auto instance = InstanceOf({ LiveAt({ 0, 30, 0 }) });
    Record(*instance, 0, 8, { { 0, 0, 0 }, { 0, 10, 0 }, { 0, 20, 0 } });
    auto mesh      = NewRopeMesh(/*thick=*/true, RopeKind::Trail);
    auto instances = Single(std::move(instance));
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 9u);
    ASSERT_EQ(Pieces(*mesh), 3u);
    const float starts[3][3] = { { 0, 30, 0 }, { 0, 20, 0 }, { 0, 10, 0 } };
    const float ends[3][3]   = { { 0, 20, 0 }, { 0, 10, 0 }, { 0, 0, 0 } };
    for (std::size_t q = 0; q < 3; ++q) {
        const Quad quad(*mesh, q);
        EXPECT_TRUE(SamePoint(quad.start(), { starts[q][0], starts[q][1], starts[q][2] })) << "piece " << q;
        EXPECT_TRUE(SamePoint(quad.end(), { ends[q][0], ends[q][1], ends[q][2] })) << "piece " << q;
        EXPECT_EQ(quad.length(), 3.0f) << "as many as the points held";
        EXPECT_EQ(quad.along(), static_cast<float>(q));
    }
}

// RG-10
// WE's trail writer (0x1402308A0) draws the recorded points where they were recorded; the
// period fraction only moves the texture coordinate.
TEST(RopePieces, AFullHistoryKeepsItsOldestPointWhereItWasRecorded) {
    for (const float fraction : { 0.0f, 0.5f, 1.0f, 7.0f }) {
        SCOPED_TRACE(fraction);
        auto instance = InstanceOf({ LiveAt({ 0, 30, 0 }) });
        Record(*instance, 0, 3, { { 0, 0, 0 }, { 0, 10, 0 }, { 0, 20, 0 } });
        auto mesh = NewRopeMesh(true, RopeKind::Trail);
        ParticleRenderScale scale;
        scale.trail_fraction = fraction;
        auto instances       = Single(std::move(instance));
        Generate(instances, *mesh, scale);
        ASSERT_EQ(Pieces(*mesh), 3u);
        const Quad first(*mesh, 0), last(*mesh, 2);
        EXPECT_TRUE(SamePoint(first.start(), { 0, 30, 0 }));
        EXPECT_TRUE(SamePoint(first.end(), { 0, 20, 0 }));
        EXPECT_EQ(first.length(), 3.0f);
        EXPECT_EQ(first.along(), 0.0f);
        EXPECT_TRUE(SamePoint(last.start(), { 0, 10, 0 }));
        EXPECT_TRUE(SamePoint(last.end(), { 0, 0, 0 }));
        EXPECT_EQ(last.along(), 2.0f);
    }
}

// RG-11
TEST(RopePieces, AParticleWithoutAHistoryAndADeadParticleDrawNothing) {
    auto instance = InstanceOf({ LiveAt({ 0, 0, 0 }), DeadAt({ 5, 0, 0 }) });
    auto& trails  = instance->TrailsVec();
    trails.resize(2);
    trails[0].Reset(4);
    trails[1].Reset(4);
    trails[1].Push(SampleAt({ 5, 0, 0 }));
    trails[1].Push(SampleAt({ 6, 0, 0 }));
    trails[1].Push(SampleAt({ 7, 0, 0 }));

    auto mesh      = NewRopeMesh(true, RopeKind::Trail);
    auto instances = Single(std::move(instance));
    Generate(instances, *mesh);
    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 0u);
}

// RG-12
TEST(RopePieces, EachParticlesTrailIsItsOwnStrip) {
    auto instance = InstanceOf({ LiveAt({ 0, 0, 0 }), LiveAt({ 10, 0, 0 }) });
    Record(*instance, 0, 4, { { -1, 0, 0 } });
    Record(*instance, 1, 4, { { 11, 0, 0 } });
    auto mesh      = NewRopeMesh(true, RopeKind::Trail);
    auto instances = Single(std::move(instance));
    Generate(instances, *mesh);

    EXPECT_EQ(mesh->GetIndexArray(0).RenderDataCount(), 6u);
    ASSERT_EQ(Pieces(*mesh), 2u);
    const Quad a(*mesh, 0), b(*mesh, 1);
    EXPECT_TRUE(SamePoint(a.start(), { 0, 0, 0 }));
    EXPECT_TRUE(SamePoint(a.end(), { -1, 0, 0 }));
    EXPECT_EQ(a.length(), 1.0f);
    EXPECT_EQ(a.along(), 0.0f);
    EXPECT_TRUE(SamePoint(b.start(), { 10, 0, 0 }));
    EXPECT_TRUE(SamePoint(b.end(), { 11, 0, 0 }));
    EXPECT_EQ(b.length(), 1.0f);
    EXPECT_EQ(b.along(), 0.0f) << "the second trail does not continue the first";
}

// RU-01
// WE stores 1 / uvscale and writes the point count times it (0x1402308A0; probe rope-uv-v3,
// where uvscale 2 and 0.5 ropes end at the coordinates this length gives).
TEST(RopeTextureRepeat, TheRecordedLengthIsThePointCountOverTheUvScale) {
    for (const auto& [uv_scale, expected_length, expected_span] :
         { std::tuple { 1.0f, 3.0f, 1.0 }, std::tuple { 2.0f, 1.5f, 4.0 }, std::tuple { 0.5f, 6.0f, 0.4 } }) {
        SCOPED_TRACE(testing::Message() << "uv_scale " << uv_scale);
        auto mesh      = NewRopeMesh(false);
        auto instances = ThreeInALine();
        ParticleRenderScale scale;
        scale.uv_scale = uv_scale;
        Generate(instances, *mesh, scale);
        EXPECT_EQ(Quad(*mesh, 0).length(), expected_length);
        EXPECT_NEAR(RepeatSpan(*mesh), expected_span, 1e-5);
    }
}

// RU-02
TEST(RopeTextureRepeat, SubdividingDoesNotAddRepeats) {
    double spans[2];
    int    slot = 0;
    for (const uint32_t subdivision : { 1u, 3u }) {
        auto mesh      = NewRopeMesh(false);
        auto instances = ThreeInALine();
        ParticleRenderScale scale;
        scale.uv_scale        = 2.0f;
        scale.rope_subdivision = subdivision;
        Generate(instances, *mesh, scale);
        ASSERT_EQ(Pieces(*mesh), 2u * subdivision);
        spans[slot++] = RepeatSpan(*mesh);
        if (subdivision == 3) EXPECT_EQ(Quad(*mesh, 0).length(), 2.5f);
    }
    EXPECT_NEAR(spans[0], 4.0, 1e-5);
    EXPECT_NEAR(spans[1], spans[0], 1e-5);
}

// RU-03
// A scrolling rope is measured against rate x lifetime less one, the rate bounded by the
// frame-rate cap while it holds fewer particles, and moves on by one for each that died
// (0x1402308A0; probe rope-uv-v4).
TEST(RopeTextureRepeat, ScrollingMeasuresAgainstRateTimesLifetimeAndMovesOnWithEachDeath) {
    for (const auto& [fps, uv_scale, expected] :
         { std::tuple { 0u, 1.0f, 39.0f }, std::tuple { 0u, 2.0f, 19.5f }, std::tuple { 3u, 1.0f, 29.0f } }) {
        SCOPED_TRACE(testing::Message() << "fps " << fps << " uv_scale " << uv_scale);
        auto mesh      = NewRopeMesh(false);
        auto instances = ThreeInALine();
        instances.front()->CountDeath();
        instances.front()->CountDeath();
        ParticleRenderScale scale;
        scale.uv_scrolling  = true;
        scale.uv_scale      = uv_scale;
        scale.rope_rate     = 4.0f;
        scale.rope_lifetime = 10.0f;
        scale.target_fps    = fps;
        Generate(instances, *mesh, scale);
        EXPECT_EQ(Quad(*mesh, 0).length(), expected);
        EXPECT_EQ(Quad(*mesh, 0).along(), 2.0f) << "two particles have died";
        EXPECT_EQ(Quad(*mesh, 1).along(), 3.0f);
    }
}

// RU-04
TEST(RopeTextureRepeat, SmoothingDrawsAsWithoutUntilTheRopeIsSteady) {
    const Point row[4] = { { 0, 0, 0 }, { 10, 0, 0 }, { 20, 0, 0 }, { 30, 0, 0 } };
    auto instances = Single(InstanceOf({ LiveAt(row[0]), LiveAt(row[1]), LiveAt(row[2]), LiveAt(row[3]) }));
    auto mesh      = NewRopeMesh(false);
    ParticleRenderScale scale;
    scale.uv_smoothing = true;
    Generate(instances, *mesh, scale);
    ASSERT_EQ(Pieces(*mesh), 3u);
    for (std::size_t i = 0; i < 3; ++i) EXPECT_EQ(Quad(*mesh, i).along(), static_cast<float>(i));
    EXPECT_EQ(Quad(*mesh, 0).length(), 4.0f);
}

// RU-04b
// A rope that holds its steady count (rate x lifetime) and `uvsmoothing` starts at the newest
// particle's age over a particle's spacing in time, saturated, less one
// (0x140230A42-0x140230A7C) and is measured against that count less one (probe rope-uv-v5).
TEST(RopeTextureRepeat, ASteadySmoothedRopeStartsAtItsFirstParticlesAge) {
    auto instance = InstanceOf({ LiveAt({ 0, 0, 0 }), LiveAt({ 10, 0, 0 }), LiveAt({ 20, 0, 0 }), LiveAt({ 30, 0, 0 }) });
    // Born 0.5 s apart; the newest has lived 0.125 s, a quarter of the 0.5 s spacing.
    const float ages[4] = { 1.625f, 1.125f, 0.625f, 0.125f };
    for (std::size_t i = 0; i < 4; ++i) {
        instance->ParticlesVec()[i].init.lifetime = 2.0f;
        instance->ParticlesVec()[i].lifetime      = 2.0f - ages[i];
    }
    auto instances = Single(std::move(instance));
    auto mesh      = NewRopeMesh(false);
    ParticleRenderScale scale;
    scale.uv_smoothing  = true;
    scale.rope_rate     = 2.0f;                     // 2 x 1 s = 2 particles, fewer than the 4 held
    scale.rope_lifetime = 1.0f;
    Generate(instances, *mesh, scale);
    ASSERT_EQ(Pieces(*mesh), 3u);
    EXPECT_EQ(Quad(*mesh, 0).length(), 1.0f) << "steady count 2, less one";
    // saturate((1 - 0.875) / (1 / 2)) - 1 = 0.25 - 1
    EXPECT_FLOAT_EQ(Quad(*mesh, 0).along(), -0.75f);
    EXPECT_FLOAT_EQ(Quad(*mesh, 2).along(), 1.25f);
}

// RU-05
TEST(RopeTextureRepeat, TheCoordinateAcrossTheRopeStaysInZeroToOneWhateverTheUvScale) {
    auto mesh      = NewRopeMesh(false);
    auto instances = ThreeInALine();
    ParticleRenderScale scale;
    scale.uv_scale = 4.0f;
    Generate(instances, *mesh, scale);
    ASSERT_EQ(Pieces(*mesh), 2u);
    for (std::size_t q = 0; q < 2; ++q) {
        for (std::size_t v = 0; v < 4; ++v) {
            EXPECT_EQ(Quad(*mesh, q).f(16, v), kCornerOrder[v][0]) << "quad " << q << " vertex " << v;
            EXPECT_EQ(Quad(*mesh, q).f(17, v), kCornerOrder[v][1]) << "quad " << q << " vertex " << v;
        }
    }
}

// RU-06
TEST(RopeTextureRepeat, ChangingTheScaleLaterRewritesTheLengthAndLeavesTheParticlesAlone) {
    auto mesh      = NewRopeMesh(false);
    auto instances = ThreeInALine();
    Generate(instances, *mesh);
    EXPECT_EQ(Quad(*mesh, 0).length(), 3.0f);

    ParticleRenderScale scale;
    scale.uv_scale = 2.0f;
    Generate(instances, *mesh, scale);
    EXPECT_EQ(Quad(*mesh, 0).length(), 1.5f);
    EXPECT_EQ(instances.front()->Particles().size(), 3u);
}

// RH-01
namespace
{

// The generator the engine would use, with a count of how often it was asked to draw.
class CountingGenerator : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances, SceneMesh& mesh,
                   ParticleRawGenSpecOp& spec, ParticleRenderScale scale,
                   ParticleOverflowFlags& flags) override {
        ++calls;
        m_inner.GenGLData(instances, mesh, spec, scale, flags);
    }
    int calls { 0 };

private:
    WPParticleRawGener m_inner;
};

// One rope-trail layer: four particles born on four successive steps, each leaving a recorded
// path, drawn into a thin rope-trail mesh.
struct TrailLayer {
    Scene                      scene;
    ParticleSystem             system { scene };
    std::shared_ptr<SceneMesh> mesh { NewRopeMesh(/*thick=*/false, RopeKind::Trail) };
    std::shared_ptr<SceneNode> parent { std::make_shared<SceneNode>() };
    std::shared_ptr<SceneNode> owner { std::make_shared<SceneNode>() };
    CountingGenerator*         generator { nullptr };

    TrailLayer() {
        scene.frameTime = 0.125;
        auto counting   = std::make_unique<CountingGenerator>();
        generator       = counting.get();
        system.gener    = std::move(counting);
        parent->AppendChild(owner);

        auto subsystem = std::make_unique<ParticleSubSystem>(
            system, mesh, 8, 1.0, 1, 1.0, ParticleSubSystem::SpawnType::STATIC,
            [](const Particle&, const ParticleRawGenSpec&) {});
        subsystem->SetTrail({ .samples = 4, .period = 0.25 });
        subsystem->SetOwnerNode(owner);
        subsystem->AddOperator([](const ParticleInfo& info) {
            for (Particle& p : info.particles) {
                if (ParticleModify::LifetimeOk(p)) ParticleModify::MoveByTime(p, info.time_pass);
            }
        });
        subsystem->AddEmitter([](std::vector<Particle>& slots, std::vector<ParticleInitOp>&, uint32_t,
                                 double, std::span<const ParticleControlpoint>) {
            if (slots.size() >= 4) return;
            const double i = static_cast<double>(slots.size());
            Particle p;
            ParticleModify::MoveTo(p, i, 2.0 * i, 0.0);
            ParticleModify::InitVelocity(p, 8.0 + i, 4.0 - i, 0.0);
            ParticleModify::InitLifetime(p, 10.0f);
            slots.push_back(p);
        });
        system.subsystems.push_back(std::move(subsystem));
    }

    // The engine's frame: simulate, let the runtime tick change visibility, then rebuild what
    // became visible.
    void Frame(const std::function<void()>& tick = {}) {
        system.Emitt();
        if (tick) tick();
        system.RebuildVisibleMeshes();
    }
};

void ExpectSameGeometry(const TrailLayer& expected, const TrailLayer& actual) {
    EXPECT_EQ(expected.mesh->GetIndexArray(0).RenderDataCount(),
              actual.mesh->GetIndexArray(0).RenderDataCount());
    const auto& a = expected.mesh->GetVertexArray(0);
    const auto& b = actual.mesh->GetVertexArray(0);
    ASSERT_EQ(a.CapacitySize(), b.CapacitySize());
    for (std::size_t i = 0; i < a.CapacitySize(); ++i) {
        ASSERT_EQ(a.Data()[i], b.Data()[i]) << "vertex float " << i;
    }
}

} // namespace

TEST(RopeHiddenLayerReveal, ALayerRevealedAfterItsStepDrawsWhatAnAlwaysVisibleRunDraws) {
    for (const bool hide_the_parent : { false, true }) {
        SCOPED_TRACE(hide_the_parent ? "the parent was hidden" : "the layer itself was hidden");
        TrailLayer reference, revealed;
        SceneNode& hidden = hide_the_parent ? *revealed.parent : *revealed.owner;
        hidden.SetVisible(false);

        for (int frame = 1; frame <= 5; ++frame) {
            reference.Frame();
            revealed.Frame();
        }
        EXPECT_EQ(revealed.generator->calls, 0) << "a hidden layer generates no geometry";
        EXPECT_EQ(reference.generator->calls, 5);

        reference.Frame();
        revealed.Frame([&] { hidden.SetVisible(true); });
        EXPECT_EQ(revealed.generator->calls, 1) << "built once, at the end of the reveal frame";
        EXPECT_GT(reference.mesh->GetIndexArray(0).RenderDataCount(), 0u);
        ExpectSameGeometry(reference, revealed);

        reference.Frame();
        revealed.Frame();
        EXPECT_EQ(revealed.generator->calls, 2);
        ExpectSameGeometry(reference, revealed);
    }
}
