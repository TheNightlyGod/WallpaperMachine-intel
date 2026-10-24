#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "RenderCommon/CopyElision.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

using wallpaper::render::CopyElision;
using wallpaper::render::DynamicReason;
using wallpaper::render::ElisionPassDesc;
using wallpaper::render::PlanCopyElision;
using wallpaper::render::ResolveCopyAliasKey;
using wallpaper::render::StaticPassDesc;
using wallpaper::render::StaticPassSample;
using wallpaper::render::StaticSubgraphCache;

namespace
{

StaticPassDesc Pass(std::string target, std::vector<std::string> inputs = {},
                    uint32_t reasons = 0)
{
    StaticPassDesc desc;
    desc.target          = std::move(target);
    desc.inputs          = std::move(inputs);
    desc.dynamic_reasons = reasons;
    return desc;
}

/// Pins every target the analysis found cacheable, as the renderer does when
/// the memory budget allows it.
void PinAllCacheable(StaticSubgraphCache& cache, uint64_t bytes = 1024)
{
    for (std::size_t i = 0; i < cache.TargetCount(); ++i) {
        if (cache.TargetCacheable(i)) cache.SetTargetPinned(i, true, bytes);
    }
}

std::vector<uint8_t> RunFrame(StaticSubgraphCache& cache, std::vector<StaticPassSample> samples)
{
    std::vector<uint8_t> skip(samples.size(), 0);
    cache.Plan(samples, skip);
    return skip;
}

ElisionPassDesc Custom(std::string writes, std::vector<std::string> reads = {})
{
    ElisionPassDesc desc;
    desc.kind   = ElisionPassDesc::Kind::Custom;
    desc.writes = std::move(writes);
    desc.reads  = std::move(reads);
    return desc;
}

ElisionPassDesc Copy(std::string dst, std::string src, bool compatible = true,
                     bool generates_mipmaps = false)
{
    ElisionPassDesc desc;
    desc.kind                   = ElisionPassDesc::Kind::Copy;
    desc.writes                 = std::move(dst);
    desc.reads                  = { std::move(src) };
    desc.copy_compatible        = compatible;
    desc.copy_generates_mipmaps = generates_mipmaps;
    return desc;
}

ElisionPassDesc Present(std::string reads)
{
    ElisionPassDesc desc;
    desc.kind  = ElisionPassDesc::Kind::Present;
    desc.reads = { std::move(reads) };
    return desc;
}

constexpr StaticPassSample kStable { .hash = 7, .visible = true };

} // namespace

TEST(StaticSubgraphCache, FirstFrameAlwaysRenders)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);

    const auto first = RunFrame(cache, { kStable });
    EXPECT_EQ(first[0], 0) << "nothing has been drawn yet, so there is nothing to reuse";

    const auto second = RunFrame(cache, { kStable });
    EXPECT_EQ(second[0], 1);
}

TEST(StaticSubgraphCache, AChangedInputReRendersItsTarget)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    const StaticPassSample moved { .hash = 99, .visible = true };
    EXPECT_EQ(RunFrame(cache, { moved })[0], 0);
    EXPECT_EQ(RunFrame(cache, { moved })[0], 1) << "the new state becomes the reusable one";
}

TEST(StaticSubgraphCache, VisibilityChangeReRendersEvenWhenTheHashIsStable)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    const StaticPassSample hidden { .hash = kStable.hash, .visible = false };
    EXPECT_EQ(RunFrame(cache, { hidden })[0], 0);
}

TEST(StaticSubgraphCache, ADynamicUniformKeepsItsWholeTargetOutOfTheCache)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_default"),
        Pass("_rt_default", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable });
    EXPECT_EQ(skip[0], 0) << "all writers of one target share its fate: the batch may clear";
    EXPECT_EQ(skip[1], 0);
}

TEST(StaticSubgraphCache, DynamicInputsPropagateDownstream)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a", {}, static_cast<uint32_t>(DynamicReason::VideoInput)),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable, kStable });
    EXPECT_EQ(skip[0], 0);
    EXPECT_EQ(skip[1], 0) << "a target fed by a video frame cannot be stable";
    EXPECT_EQ(skip[2], 0);
}

TEST(StaticSubgraphCache, AnUnchangedChainIsReusedEndToEnd)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable, kStable });
    EXPECT_EQ(skip[0], 1);
    EXPECT_EQ(skip[1], 1);
    EXPECT_EQ(skip[2], 1);
}

TEST(StaticSubgraphCache, AChangeAtTheHeadInvalidatesEverythingBelowIt)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable, kStable, kStable });
    ASSERT_EQ(RunFrame(cache, { kStable, kStable, kStable })[2], 1);

    const StaticPassSample moved { .hash = 4242, .visible = true };
    const auto             skip = RunFrame(cache, { moved, kStable, kStable });
    EXPECT_EQ(skip[0], 0);
    EXPECT_EQ(skip[1], 0) << "its input was redrawn, so its own pixels are stale";
    EXPECT_EQ(skip[2], 0);
}

TEST(StaticSubgraphCache, AnUnpinnedTargetIsNeverReused)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    // Deliberately not pinned: the render-target pool may hand this image to
    // another key, so last frame's pixels are not guaranteed to still be there.
    RunFrame(cache, { kStable });
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
}

TEST(StaticSubgraphCache, UnpinningDropsTheRetainedResult)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    cache.SetTargetPinned(0, false, 0);
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
    EXPECT_EQ(cache.stats().pinned_bytes, 0u);
}

TEST(StaticSubgraphCache, FeedbackIsNeverCached)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_a", { "_rt_a" }) });
    ASSERT_EQ(cache.TargetCount(), 1u);
    EXPECT_FALSE(cache.TargetCacheable(0));
    EXPECT_TRUE(cache.TargetDynamicReasons(0) & DynamicReason::Feedback);
}

TEST(StaticSubgraphCache, ADependencyCycleLosesCacheabilityRatherThanReadingStaleInputs)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a", { "_rt_b" }),
        Pass("_rt_b", { "_rt_a" }),
    });
    EXPECT_FALSE(cache.TargetCacheable(0));
    EXPECT_FALSE(cache.TargetCacheable(1));
}

TEST(StaticSubgraphCache, InvalidateAllForcesOneFullRedraw)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    cache.InvalidateAll();
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 1);
}

TEST(StaticSubgraphCache, StatsCountEveryPassExactlyOnce)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable });
    RunFrame(cache, { kStable, kStable });
    const auto& stats = cache.stats();
    EXPECT_EQ(stats.executed_passes + stats.skipped_passes, 4u);
    EXPECT_EQ(stats.skipped_passes, 1u) << "only the static target is reused, on the second frame";
}

TEST(StaticSubgraphCache, OnlyWritersOfCacheableTargetsAreSampled)
{
    // What `Plan` reads decides what a renderer has to measure every frame.
    // The writers of a target that is never reused -- dynamic itself, or fed
    // by one -- and a pass that writes nothing tracked execute whatever their
    // sample says, so taking one is work with no reachable result.
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_clock", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
        Pass("_rt_face", { "_rt_clock" }),
        Pass("_rt_static"),
        Pass(""),
    });
    PinAllCacheable(cache);
    EXPECT_FALSE(cache.PassSampled(0)) << "a time-driven target is redrawn every frame";
    EXPECT_FALSE(cache.PassSampled(1)) << "a reader of a dynamic target is redrawn with it";
    EXPECT_TRUE(cache.PassSampled(2));
    EXPECT_FALSE(cache.PassSampled(3)) << "a pass with no target always executes";
    EXPECT_FALSE(cache.PassSampled(4));

    // And the plan agrees: an unsampled pass may report anything without
    // changing what is reused.
    RunFrame(cache, { kStable, kStable, kStable, kStable });
    const StaticPassSample untaken {};
    const auto             skip = RunFrame(cache, { untaken, untaken, kStable, untaken });
    EXPECT_EQ(skip[2], 1) << "reusing the static target depended on a sample nobody takes";
    EXPECT_EQ(skip[0], 0);
    EXPECT_EQ(skip[1], 0);
    EXPECT_EQ(skip[3], 0);
}

TEST(CopyElisionPlan, ACopyNobodyReadsIsRemoved)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_unused", "_rt_a"),
        Present("_rt_a"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::Dead);
}

TEST(CopyElisionPlan, ACopyOfAnImageNothingRewritesBecomesAnAlias)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_snapshot", "_rt_a"),
        Custom("_rt_default", { "_rt_snapshot" }),
        Present("_rt_default"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::Alias);
}

TEST(CopyElisionPlan, AFeedbackCopyIsKept)
{
    // The source is written again after the copy, which is the entire reason
    // the copy exists: it holds the previous contents for the pass below.
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_prev", "_rt_a"),
        Custom("_rt_a", { "_rt_prev" }),
        Present("_rt_a"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::None);
}

TEST(CopyElisionPlan, AnIncompatibleCopyIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a", /*compatible=*/false),
        Custom("_rt_default", { "_rt_b" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ACopyThatBuildsAMipChainIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_mipped", "_rt_a", /*compatible=*/true, /*generates_mipmaps=*/true),
        Custom("_rt_default", { "_rt_mipped" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ACopyWhoseDestinationIsWrittenElsewhereIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a"),
        Custom("_rt_b"),
        Custom("_rt_default", { "_rt_b" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ADestinationReadBeforeTheCopyIsKept)
{
    // The earlier read consumes what the target held before this frame's copy,
    // which aliasing would replace with the source's current contents.
    const std::vector passes {
        Custom("_rt_default", { "_rt_b" }),
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a"),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[2], CopyElision::None);
}

TEST(CopyElisionPlan, ThePresentedTargetIsNotTreatedAsUnread)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_default", "_rt_a"),
        Present("_rt_default"),
    };
    EXPECT_NE(PlanCopyElision(passes)[1], CopyElision::Dead)
        << "the final blit reads it, so its result has a consumer";
}


// ---------------------------------------------------------------------------
// An aliased destination names its source's image, and the reuse analysis has
// to see that. Found while porting this analysis to the native backend.

TEST(CopyAliasResolution, AnAliasedNameResolvesThroughItsChain)
{
    const std::unordered_map<std::string, std::string> aliases {
        { "_rt_link_1", "_rt_effect_a" },
        { "_rt_link_2", "_rt_link_1" },
    };
    EXPECT_EQ(ResolveCopyAliasKey(aliases, "_rt_link_2"), "_rt_effect_a");
    EXPECT_EQ(ResolveCopyAliasKey(aliases, "_rt_effect_a"), "_rt_effect_a");
    EXPECT_EQ(ResolveCopyAliasKey(aliases, "_rt_other"), "_rt_other");
    EXPECT_EQ(ResolveCopyAliasKey({}, "_rt_link_1"), "_rt_link_1");
}

TEST(CopyAliasResolution, ACycleTerminatesInsteadOfHanging)
{
    // The planner cannot produce one -- an alias destination has no other
    // writer -- but a resolver that trusts that is a resolver that hangs if it
    // ever stops being true.
    const std::unordered_map<std::string, std::string> aliases {
        { "_rt_a", "_rt_b" },
        { "_rt_b", "_rt_a" },
    };
    const auto resolved = ResolveCopyAliasKey(aliases, "_rt_a");
    EXPECT_TRUE(resolved == "_rt_a" || resolved == "_rt_b");
}

TEST(StaticSubgraphCacheTest, AReaderOfAnAliasedDestinationInheritsItsSourcesDynamism)
{
    // The shape: a time-varying layer draws `_rt_effect_a`, a copy of it into
    // `_rt_link_1` is aliased away, and a still effect samples `_rt_link_1`.
    // Unresolved, `_rt_link_1` is a name no pass writes, so the reader looks
    // like it depends on nothing and its target is called reusable -- while the
    // pixels behind that name are redrawn every frame.
    const std::unordered_map<std::string, std::string> aliases {
        { "_rt_link_1", "_rt_effect_a" },
    };

    StaticSubgraphCache unresolved;
    unresolved.Compile(std::vector {
        Pass("_rt_effect_a", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
        Pass("_rt_default", { "_rt_link_1" }),
    });
    bool output_cacheable_unresolved = false;
    for (std::size_t i = 0; i < unresolved.TargetCount(); ++i) {
        if (unresolved.TargetKey(i) == "_rt_default") {
            output_cacheable_unresolved = unresolved.TargetCacheable(i);
        }
    }
    ASSERT_TRUE(output_cacheable_unresolved)
        << "the unresolved shape is not the one this test is about";

    StaticSubgraphCache resolved;
    resolved.Compile(std::vector {
        Pass("_rt_effect_a", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
        Pass("_rt_default", { ResolveCopyAliasKey(aliases, "_rt_link_1") }),
    });
    for (std::size_t i = 0; i < resolved.TargetCount(); ++i) {
        if (resolved.TargetKey(i) != "_rt_default") continue;
        EXPECT_FALSE(resolved.TargetCacheable(i))
            << "a reader of an aliased destination was cached although its source is redrawn "
               "every frame";
    }
}

/// The two questions a rewritten mesh answers, which are not the same answer.
///
/// `EventMesh` and `DynamicMesh` both cost a target its cacheability, because
/// either one means the vertices behind it may differ from the ones the cached
/// pixels were drawn from. Only one of them means the scene has to keep
/// drawing. Asserting both halves here keeps a future simplification from
/// collapsing them back into one bit.
TEST(SceneDemandMapping, GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing)
{
    using wallpaper::SceneDemandReason;
    using wallpaper::SceneDemandReasonsFromShaderInputs;

    const auto per_frame =
        SceneDemandReasonsFromShaderInputs(static_cast<uint32_t>(DynamicReason::DynamicMesh));
    EXPECT_TRUE(per_frame & SceneDemandReason::DynamicMesh)
        << "a mesh rewritten every frame stopped being a reason to keep the clock";

    const auto on_event =
        SceneDemandReasonsFromShaderInputs(static_cast<uint32_t>(DynamicReason::EventMesh));
    EXPECT_EQ(on_event, 0u)
        << "a mesh rewritten only when an event re-lays it out was read as continuous work";

    // And the pixel cache, which asks the other question, refuses both.
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_event", {}, static_cast<uint32_t>(DynamicReason::EventMesh)),
        Pass("_rt_per_frame", {}, static_cast<uint32_t>(DynamicReason::DynamicMesh)),
        Pass("_rt_still", {}),
    });
    for (std::size_t i = 0; i < cache.TargetCount(); ++i) {
        const auto key = cache.TargetKey(i);
        if (key == "_rt_still") {
            EXPECT_TRUE(cache.TargetCacheable(i)) << "the control target stopped being cacheable";
        } else {
            EXPECT_FALSE(cache.TargetCacheable(i))
                << "target " << key << " was cached although its geometry may have been rewritten";
        }
    }
}
