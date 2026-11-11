#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "RenderCommon/CopyElision.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
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

TEST(StaticSubgraphCache, ADelayedReaderCatchesUpAfterOneSourceChange)
{
    auto reader = Pass("reader");
    reader.previous_inputs = { "source" };
    StaticSubgraphCache cache;
    cache.Compile(std::vector { reader, Pass("source") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable, kStable });
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 0, 1 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 1, 1 }));

    const StaticPassSample changed { .hash = 99 };
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 1, 0 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 0, 1 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 1, 1 }));
}

TEST(StaticSubgraphCache, DelayedInputsRetainSignaturesFromUnpinnedSources)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("reader", { "source" }), Pass("source") });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    cache.SetTargetPinned(0, true, 1024);
    RunFrame(cache, { kStable, kStable });
    RunFrame(cache, { kStable, kStable });
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 1, 0 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());

    const StaticPassSample changed { .hash = 99 };
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 1, 0 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 0, 0 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

TEST(StaticSubgraphCache, ChangingExecutionOrderChangesReadTimingWithoutDroppingPins)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("reader", { "source" }), Pass("source") });
    PinAllCacheable(cache);
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    RunFrame(cache, { kStable, kStable });
    RunFrame(cache, { kStable, kStable });
    const auto pinned = cache.stats().pinned_bytes;

    cache.SetExecutionOrder(std::vector<std::size_t> { 1, 0 });
    const StaticPassSample changed { .hash = 99 };
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 0, 0 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(cache.stats().pinned_bytes, pinned);
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 1, 1 }));

    cache.SetPreviousFrameInputs(std::vector<wallpaper::render::StaticPreviousFrameInput> {
        { 0, "source" },
    });
    EXPECT_EQ(RunFrame(cache, { kStable, changed }), (std::vector<uint8_t> { 0, 1 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

TEST(StaticSubgraphCache, OneTargetCanConsumeCurrentAndPreviousSourceVersions)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("reader", { "source" }), Pass("source"), Pass("reader", { "source" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2 });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable, kStable, kStable });
    RunFrame(cache, { kStable, kStable, kStable });
    const StaticPassSample changed { .hash = 99 };
    EXPECT_EQ(RunFrame(cache, { kStable, changed, kStable }),
              (std::vector<uint8_t> { 0, 0, 0 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, changed, kStable }),
              (std::vector<uint8_t> { 0, 1, 0 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, changed, kStable }),
              (std::vector<uint8_t> { 1, 1, 1 }));
}

TEST(StaticSubgraphCache, ADelayedEdgeDoesNotMakeAFeedbackCycleCacheable)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("a", { "b" }), Pass("b", { "a" }) });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    EXPECT_TRUE(cache.HasFeedbackCycles());
    for (std::size_t i = 0; i < cache.TargetCount(); ++i) {
        EXPECT_FALSE(cache.TargetCacheable(i));
        EXPECT_TRUE(cache.TargetDynamicReasons(i) & DynamicReason::Feedback);
    }
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 0, 0 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

TEST(StaticSubgraphCache, DelayedEventGeometryKeepsOnlyItsCatchUpFramePending)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("reader", { "source" }),
        Pass("source", {}, static_cast<uint32_t>(DynamicReason::EventMesh)),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    EXPECT_TRUE(cache.PassSampled(0));
    EXPECT_TRUE(cache.PassSampled(1));
    EXPECT_FALSE(cache.TargetCacheable(0));
    EXPECT_FALSE(cache.TargetCacheable(1));
    RunFrame(cache, { kStable, kStable });
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    RunFrame(cache, { kStable, kStable });
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    RunFrame(cache, { kStable, { .hash = 99 } });
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    RunFrame(cache, { kStable, { .hash = 99 } });
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

TEST(StaticSubgraphCache, ClearingRetainedPixelsRestartsDelayedInitialization)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("reader", { "source" }), Pass("source") });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable, kStable });
    RunFrame(cache, { kStable, kStable });
    cache.InvalidateAll();
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 0, 0 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable }), (std::vector<uint8_t> { 0, 1 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

TEST(StaticSubgraphCache, ADelayedChainRequestsOnlyItsRemainingPropagationFrames)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("last", { "middle" }), Pass("middle", { "source" }), Pass("source"),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2 });
    PinAllCacheable(cache);
    EXPECT_TRUE(cache.HasDelayedInputs());
    EXPECT_FALSE(cache.HasFeedbackCycles());
    EXPECT_TRUE(cache.TargetReadFromPreviousFrame(1));
    EXPECT_TRUE(cache.TargetReadFromPreviousFrame(2));
    for (int frame = 0; frame < 3; ++frame) RunFrame(cache, { kStable, kStable, kStable });
    ASSERT_FALSE(cache.HasPendingDelayedInputs());

    const StaticPassSample changed { .hash = 99 };
    EXPECT_EQ(RunFrame(cache, { kStable, kStable, changed }),
              (std::vector<uint8_t> { 1, 1, 0 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable, changed }),
              (std::vector<uint8_t> { 1, 0, 1 }));
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable, changed }),
              (std::vector<uint8_t> { 0, 1, 1 }));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_EQ(RunFrame(cache, { kStable, kStable, changed }),
              (std::vector<uint8_t> { 1, 1, 1 }));
}

TEST(StaticSubgraphCache, CurrentFrameSnapshotCyclesDoNotKeepTheIdleClockRunning)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("scene"), Pass("snapshot", { "scene" }),
        Pass("effect", { "snapshot" }), Pass("scene", { "effect" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3 });
    EXPECT_FALSE(cache.HasDelayedInputs());
    EXPECT_FALSE(cache.HasFeedbackCycles());
    for (std::size_t i = 0; i < cache.TargetCount(); ++i)
        EXPECT_FALSE(cache.TargetCacheable(i));

    cache.SetExecutionOrder(std::vector<std::size_t> { 1, 2, 0, 3 });
    EXPECT_TRUE(cache.HasDelayedInputs());
    EXPECT_TRUE(cache.HasFeedbackCycles());
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3 });
    EXPECT_FALSE(cache.HasFeedbackCycles());
}

TEST(StaticSubgraphCache, ADelayedReaderOfACurrentFrameCycleIsNotItselfFeedback)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("reader", { "effect" }), Pass("scene"),
        Pass("snapshot", { "scene" }), Pass("effect", { "snapshot" }),
        Pass("scene", { "effect" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3, 4 });
    EXPECT_TRUE(cache.HasDelayedInputs());
    EXPECT_FALSE(cache.HasFeedbackCycles());
}

TEST(StaticSubgraphCache, ADelayedReaderOfASnapshotCycleCatchesUpAfterAnEvent)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("reader", { "effect" }), Pass("scene"),
        Pass("snapshot", { "scene" }), Pass("effect", { "snapshot" }),
        Pass("scene", { "effect" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3, 4 });
    ASSERT_FALSE(cache.HasFeedbackCycles());
    for (std::size_t i = 0; i < 5; ++i) EXPECT_TRUE(cache.PassSampled(i));
    RunFrame(cache, { kStable, kStable, kStable, kStable, kStable });
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    RunFrame(cache, { kStable, kStable, kStable, kStable, kStable });
    EXPECT_FALSE(cache.HasPendingDelayedInputs());

    const StaticPassSample changed { .hash = 99 };
    RunFrame(cache, { kStable, changed, kStable, kStable, kStable });
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    RunFrame(cache, { kStable, changed, kStable, kStable, kStable });
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_FALSE(cache.HasFeedbackCycles());
}

TEST(StaticSubgraphCache, ACurrentFrameCycleWithoutDelayedReadersDoesNotSampleWriters)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("scene"), Pass("snapshot", { "scene" }),
        Pass("effect", { "snapshot" }), Pass("scene", { "effect" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3 });
    for (std::size_t i = 0; i < 4; ++i) EXPECT_FALSE(cache.PassSampled(i));
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
    EXPECT_FALSE(cache.HasFeedbackCycles());
}

TEST(StaticSubgraphCache, ReorderedCopyWritersInvalidateTheirSharedTarget)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("red"), Pass("green"),
        Pass("output", { "red" }), Pass("output", { "green" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3 });
    PinAllCacheable(cache);
    const std::vector<StaticPassSample> samples {
        { .hash = 17 }, { .hash = 99 }, {}, {},
    };
    RunFrame(cache, samples);
    ASSERT_EQ(RunFrame(cache, samples), (std::vector<uint8_t> { 1, 1, 1, 1 }));

    // Both copies have identical per-pass samples and the same union of input
    // targets. Only which source is copied last changes the retained picture.
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 3, 2 });
    EXPECT_EQ(RunFrame(cache, samples), (std::vector<uint8_t> { 1, 1, 0, 0 }));
    EXPECT_EQ(RunFrame(cache, samples), (std::vector<uint8_t> { 1, 1, 1, 1 }));
}

TEST(StaticSubgraphCache, ReorderedCopiesInsideASnapshotCycleRequestDelayedCatchUp)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("reader", { "output" }), Pass("output"),
        Pass("red", { "output" }), Pass("green"),
        Pass("output", { "red" }), Pass("output", { "green" }),
    });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3, 4, 5 });
    const std::vector<StaticPassSample> samples {
        {}, {}, { .hash = 17 }, { .hash = 99 }, {}, {},
    };
    RunFrame(cache, samples);
    RunFrame(cache, samples);
    ASSERT_FALSE(cache.HasPendingDelayedInputs());
    ASSERT_FALSE(cache.HasFeedbackCycles());

    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1, 2, 3, 5, 4 });
    RunFrame(cache, samples);
    EXPECT_TRUE(cache.HasPendingDelayedInputs());
    RunFrame(cache, samples);
    EXPECT_FALSE(cache.HasPendingDelayedInputs());
}

// ---- the sample hash
//
// Only equality of two samples is ever asked, so what matters is that inputs
// that differ give samples that differ, and that equal inputs give equal ones.

TEST(StaticSampleHash, EveryByteOfARunCountsWhereverItIs)
{
    using wallpaper::render::StaticHashBytes;
    // A matrix of doubles, as a node transform or a camera is folded.
    std::array<unsigned char, 128> bytes {};
    for (std::size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<unsigned char>(i * 37 + 11);
    const uint64_t seed = 0xcbf29ce484222325ULL;
    const auto     base = StaticHashBytes(seed, bytes.data(), bytes.size());
    EXPECT_EQ(StaticHashBytes(seed, bytes.data(), bytes.size()), base);
    for (std::size_t at = 0; at < bytes.size(); ++at) {
        for (const unsigned char flip : { 0x01, 0x80, 0xFF }) {
            auto changed = bytes;
            changed[at] ^= flip;
            EXPECT_NE(StaticHashBytes(seed, changed.data(), changed.size()), base)
                << "byte " << at << " changed by " << int(flip) << " left the sample unchanged";
        }
    }
    // Every length, so a tail of fewer than eight bytes counts as well.
    for (std::size_t size = 1; size <= 17; ++size) {
        auto changed = bytes;
        changed[size - 1] ^= 0x10;
        EXPECT_NE(StaticHashBytes(seed, changed.data(), size), StaticHashBytes(seed, bytes.data(), size))
            << "the last byte of a run of " << size << " did not count";
    }
}

TEST(StaticSampleHash, ARunIsNotAShorterRunNorTheSameBytesSplitElsewhere)
{
    using wallpaper::render::StaticHashBytes;
    const uint64_t      seed = 0xcbf29ce484222325ULL;
    const unsigned char zeros[9] {};
    // A zero-padded tail is not a shorter run.
    for (std::size_t size = 0; size < 9; ++size) {
        EXPECT_NE(StaticHashBytes(seed, zeros, size), StaticHashBytes(seed, zeros, size + 1))
            << size << " zero bytes hash like " << size + 1;
    }
    // A material constant's name and value are folded one after the other: a
    // boundary that moves is a different pair.
    const std::string text = "g_Strength0123";
    for (std::size_t split = 1; split + 1 < text.size(); ++split) {
        const auto first = StaticHashBytes(StaticHashBytes(seed, text.data(), split),
                                           text.data() + split, text.size() - split);
        const auto other = StaticHashBytes(StaticHashBytes(seed, text.data(), split + 1),
                                           text.data() + split + 1, text.size() - split - 1);
        EXPECT_NE(first, other) << "splitting at " << split << " or " << split + 1 << " collided";
    }
}

TEST(StaticSampleHash, ValuesFoldedInAnotherOrderAreAnotherSample)
{
    using wallpaper::render::StaticHashMix;
    const uint64_t                seed = 0xcbf29ce484222325ULL;
    const std::array<uint64_t, 6> values { 0, 1, 2, 640, 0x3FF0000000000000ULL, ~0ULL };
    for (const auto a : values) {
        for (const auto b : values) {
            if (a == b) continue;
            EXPECT_NE(StaticHashMix(StaticHashMix(seed, a), b), StaticHashMix(StaticHashMix(seed, b), a))
                << a << " then " << b << " folded like " << b << " then " << a;
            EXPECT_NE(StaticHashMix(seed, a), StaticHashMix(seed, b));
        }
    }
}

namespace
{

/// What one pass of the random graphs below reads, kept whole: two values and a
/// matrix, the shape of a pass sample's real inputs.
struct PassInputs
{
    uint64_t               first { 0 };
    uint64_t               second { 0 };
    std::array<double, 16> matrix {};
    bool                   visible { true };

    std::string Exact() const
    {
        std::string out(reinterpret_cast<const char*>(&first), sizeof(first));
        out.append(reinterpret_cast<const char*>(&second), sizeof(second));
        out.append(reinterpret_cast<const char*>(matrix.data()), sizeof(double) * matrix.size());
        out.push_back(visible ? '1' : '0');
        return out;
    }

    StaticPassSample Sample() const
    {
        using wallpaper::render::StaticHashBytes;
        using wallpaper::render::StaticHashMix;
        uint64_t hash = 0xcbf29ce484222325ULL;
        hash          = StaticHashMix(hash, first);
        hash          = StaticHashMix(hash, second);
        hash          = StaticHashBytes(hash, matrix.data(), sizeof(double) * matrix.size());
        return { .hash = hash, .visible = visible };
    }
};

} // namespace

TEST(StaticSampleHash, ReuseDecisionsAreThoseOfComparingEveryInputExactly)
{
    // The hash decides nothing of its own: a target is reused exactly when every
    // input of every pass that writes it, and of every target it reads, is what
    // it was last frame. Random graphs and random edits -- one bit, one value,
    // two values swapped, a matrix entry negated, a change undone the next frame
    // -- are planned through the cache and against an oracle that compares the
    // inputs themselves.
    uint64_t   random_state = 0x9E3779B97F4A7C15ULL;
    const auto random       = [&random_state](uint64_t bound) {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 7;
        random_state ^= random_state << 17;
        return random_state % bound;
    };
    std::size_t reused = 0;
    std::size_t drawn  = 0;
    for (int graph = 0; graph < 20; ++graph) {
        const std::size_t target_count = 4 + random(10);
        const std::size_t pass_count   = target_count + random(target_count);
        // Every target has a writer; a pass reads only targets before its own,
        // so the graph has no cycle.
        std::vector<std::size_t>              writes(pass_count);
        std::vector<std::vector<std::size_t>> reads(pass_count);
        std::vector<StaticPassDesc>           passes;
        for (std::size_t p = 0; p < pass_count; ++p) {
            writes[p] = p < target_count ? p : random(target_count);
            std::vector<std::string> inputs;
            for (std::size_t t = 0; t < writes[p]; ++t) {
                if (random(3) != 0) continue;
                reads[p].push_back(t);
                inputs.push_back("t" + std::to_string(t));
            }
            passes.push_back(Pass("t" + std::to_string(writes[p]), inputs));
        }
        // Passes in the order of the targets they write, as the renderer's list is.
        std::vector<std::size_t> order(pass_count);
        for (std::size_t p = 0; p < pass_count; ++p) order[p] = p;
        std::stable_sort(order.begin(), order.end(),
                         [&](std::size_t a, std::size_t b) { return writes[a] < writes[b]; });
        StaticSubgraphCache cache;
        cache.Compile(passes);
        cache.SetExecutionOrder(order);
        PinAllCacheable(cache);
        ASSERT_EQ(cache.stats().cacheable_targets, target_count);

        std::vector<PassInputs> inputs(pass_count);
        for (auto& pass : inputs) {
            pass.first  = random(1000);
            pass.second = random(4);
            for (auto& value : pass.matrix) value = double(random(9)) - 4.0;
        }
        std::vector<std::string> last_exact(target_count);
        bool                     first_frame = true;
        std::vector<PassInputs>  undo;
        for (int frame = 0; frame < 60; ++frame) {
            // Edits, some of them undone on the next frame.
            if (! undo.empty()) {
                inputs = undo;
                undo.clear();
            }
            const auto edits = random(3);
            if (edits != 0 && random(4) == 0) undo = inputs;
            for (uint64_t e = 0; e < edits; ++e) {
                auto& pass = inputs[random(pass_count)];
                switch (random(6)) {
                case 0: pass.first += 1; break;
                case 1: std::swap(pass.first, pass.second); break;
                case 2: pass.matrix[random(16)] = -pass.matrix[random(16)]; break;
                case 3: {
                    auto* bytes = reinterpret_cast<unsigned char*>(pass.matrix.data());
                    bytes[random(sizeof(double) * 16)] ^= static_cast<unsigned char>(1u << random(8));
                    break;
                }
                case 4: pass.visible = ! pass.visible; break;
                default: break; // written again with what it holds
                }
            }

            // The oracle: each target's inputs in full, its sources' included.
            std::vector<std::string> exact(target_count);
            for (std::size_t t = 0; t < target_count; ++t) {
                for (const auto p : order) {
                    if (writes[p] != t) continue;
                    exact[t] += inputs[p].Exact();
                    for (const auto source : reads[p]) exact[t] += "<" + exact[source] + ">";
                }
            }
            std::vector<StaticPassSample> samples;
            for (const auto& pass : inputs) samples.push_back(pass.Sample());
            const auto skip = RunFrame(cache, samples);
            for (std::size_t p = 0; p < pass_count; ++p) {
                const auto t        = writes[p];
                const bool expected = ! first_frame && exact[t] == last_exact[t];
                ASSERT_EQ(skip[p] != 0, expected)
                    << "graph " << graph << ", frame " << frame << ", pass " << p << " (target t" << t
                    << ")";
                (expected ? reused : drawn) += 1;
            }
            last_exact  = exact;
            first_frame = false;
        }
    }
    // Both answers occurred, so neither half of the comparison is vacuous.
    EXPECT_GT(reused, 1000u);
    EXPECT_GT(drawn, 1000u);
}
