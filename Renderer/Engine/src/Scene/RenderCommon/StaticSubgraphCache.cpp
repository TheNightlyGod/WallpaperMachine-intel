#include "RenderCommon/StaticSubgraphCache.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>

using namespace wallpaper::render;

namespace
{

constexpr uint64_t kFnvOffset = 1469598103934665603ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;

} // namespace

uint64_t wallpaper::render::StaticHashMix(uint64_t seed, uint64_t value)
{
    // The seed is folded byte by byte so that two different orderings of the
    // same values do not collide, which matters because a pass sample is the
    // concatenation of several unrelated quantities.
    for (int shift = 0; shift < 64; shift += 8) {
        seed ^= static_cast<uint64_t>((value >> shift) & 0xFFULL);
        seed *= kFnvPrime;
    }
    return seed;
}

uint64_t wallpaper::render::StaticHashBytes(uint64_t seed, const void* data, std::size_t size)
{
    const auto* bytes = static_cast<const unsigned char*>(data);
    for (std::size_t i = 0; i < size; ++i) {
        seed ^= static_cast<uint64_t>(bytes[i]);
        seed *= kFnvPrime;
    }
    return seed;
}

void StaticSubgraphCache::Reset()
{
    m_targets.clear();
    m_pass_target.clear();
    m_plan_order.clear();
    m_stats = Stats {};
}

std::size_t StaticSubgraphCache::targetIndex(const std::string& key) const
{
    for (std::size_t i = 0; i < m_targets.size(); ++i) {
        if (m_targets[i].key == key) return i;
    }
    return kNoTarget;
}

void StaticSubgraphCache::Compile(std::span<const StaticPassDesc> passes)
{
    Reset();
    m_pass_target.assign(passes.size(), kNoTarget);

    for (std::size_t pass = 0; pass < passes.size(); ++pass) {
        const auto& desc = passes[pass];
        if (desc.target.empty()) continue;
        auto index = targetIndex(desc.target);
        if (index == kNoTarget) {
            index = m_targets.size();
            m_targets.push_back(Target { .key = desc.target });
        }
        m_pass_target[pass] = index;
        m_targets[index].writers.push_back(pass);
        m_targets[index].dynamic_reasons |= desc.dynamic_reasons;
    }

    for (std::size_t pass = 0; pass < passes.size(); ++pass) {
        const auto target = m_pass_target[pass];
        if (target == kNoTarget) continue;
        for (const auto& input : passes[pass].inputs) {
            const auto input_index = targetIndex(input);
            // An input that is not a render target is an uploaded image: it
            // cannot change without a graph rebuild, so it adds no dependency.
            if (input_index == kNoTarget) continue;
            if (input_index == target) {
                // Reading the target it writes is feedback: the previous
                // contents are the input, so reuse would freeze the loop.
                m_targets[target].dynamic_reasons |= DynamicReason::Feedback;
                continue;
            }
            auto& inputs = m_targets[target].inputs;
            if (std::find(inputs.begin(), inputs.end(), input_index) == inputs.end())
                inputs.push_back(input_index);
        }
    }

    for (auto& target : m_targets) target.cacheable = target.dynamic_reasons == 0;
    propagateDynamic();
    orderTargets();

    m_stats.cacheable_targets = 0;
    for (const auto& target : m_targets) {
        if (target.cacheable) ++m_stats.cacheable_targets;
    }
}

void StaticSubgraphCache::propagateDynamic()
{
    // Non-cacheability only ever spreads, so repeating the sweep until nothing
    // changes terminates in at most one pass per target.
    bool changed = true;
    while (changed) {
        changed = false;
        for (auto& target : m_targets) {
            if (! target.cacheable) continue;
            for (const auto input : target.inputs) {
                if (m_targets[input].cacheable) continue;
                target.cacheable = false;
                target.dynamic_reasons |= DynamicReason::UnknownInput;
                changed = true;
                break;
            }
        }
    }
}

void StaticSubgraphCache::orderTargets()
{
    // A cacheable target's signature folds in its inputs' signatures, so inputs
    // must be evaluated first. Anything left over after the sweep sits in a
    // dependency cycle and cannot be ordered; it loses cacheability rather than
    // being evaluated against a stale input.
    m_plan_order.clear();
    std::vector<bool> placed(m_targets.size(), false);
    bool progressed = true;
    while (progressed) {
        progressed = false;
        for (std::size_t i = 0; i < m_targets.size(); ++i) {
            if (placed[i] || ! m_targets[i].cacheable) continue;
            const bool ready = std::all_of(
                m_targets[i].inputs.begin(), m_targets[i].inputs.end(), [&](std::size_t input) {
                    return placed[input] || ! m_targets[input].cacheable;
                });
            if (! ready) continue;
            placed[i] = true;
            m_plan_order.push_back(i);
            progressed = true;
        }
    }
    for (std::size_t i = 0; i < m_targets.size(); ++i) {
        if (m_targets[i].cacheable && ! placed[i]) {
            m_targets[i].cacheable = false;
            m_targets[i].dynamic_reasons |= DynamicReason::Feedback;
        }
    }
}

void StaticSubgraphCache::SetTargetPinned(std::size_t index, bool pinned, uint64_t bytes)
{
    if (index >= m_targets.size()) return;
    auto& target = m_targets[index];
    if (target.pinned == pinned && target.pinned_bytes == (pinned ? bytes : 0)) return;
    if (target.pinned) {
        m_stats.pinned_bytes -= target.pinned_bytes;
        if (m_stats.pinned_targets > 0) --m_stats.pinned_targets;
    }
    target.pinned = pinned;
    target.pinned_bytes = pinned ? bytes : 0;
    if (pinned) {
        m_stats.pinned_bytes += bytes;
        ++m_stats.pinned_targets;
    } else {
        // Its image may be handed to another key, so the retained pixels are no
        // longer the ones this target last wrote.
        target.rendered_once = false;
    }
}

void StaticSubgraphCache::InvalidateAll()
{
    for (auto& target : m_targets) {
        target.rendered_once = false;
        target.last_signature = 0;
        target.frame_signature = 0;
    }
}

void StaticSubgraphCache::Plan(std::span<const StaticPassSample> samples,
                               std::span<uint8_t>                out_skip)
{
    const auto count = std::min(out_skip.size(), m_pass_target.size());
    std::fill(out_skip.begin(), out_skip.end(), uint8_t { 0 });
    if (samples.size() < count) return;

    for (auto& target : m_targets) target.frame_signature = 0;

    for (const auto index : m_plan_order) {
        auto& target = m_targets[index];
        uint64_t signature = kFnvOffset;
        for (const auto writer : target.writers) {
            if (writer >= samples.size()) continue;
            signature = StaticHashMix(signature, samples[writer].hash);
            signature = StaticHashMix(signature, samples[writer].visible ? 1u : 0u);
        }
        for (const auto input : target.inputs) {
            // A non-cacheable input re-renders every frame, so its contents are
            // never a stable dependency; `propagateDynamic` has already removed
            // this target from the cacheable set in that case.
            signature = StaticHashMix(signature, m_targets[input].frame_signature);
        }
        target.frame_signature = signature;
    }

    uint64_t skipped = 0;
    uint64_t executed = 0;
    for (std::size_t pass = 0; pass < count; ++pass) {
        const auto index = m_pass_target[pass];
        if (index == kNoTarget) {
            ++executed;
            continue;
        }
        auto& target = m_targets[index];
        const bool reusable = target.cacheable && target.pinned && target.rendered_once &&
                              target.frame_signature == target.last_signature;
        out_skip[pass] = reusable ? uint8_t { 1 } : uint8_t { 0 };
        if (reusable)
            ++skipped;
        else
            ++executed;
    }

    for (const auto index : m_plan_order) {
        auto& target = m_targets[index];
        if (! target.pinned) continue;
        const bool reusable = target.rendered_once && target.frame_signature == target.last_signature;
        if (reusable) continue;
        target.last_signature = target.frame_signature;
        target.rendered_once = true;
    }

    m_stats.skipped_passes += skipped;
    m_stats.executed_passes += executed;
}

namespace
{

std::atomic<bool>     g_scene_optimization_enabled { true };
std::atomic<uint64_t> g_executed_passes { 0 };
std::atomic<uint64_t> g_skipped_passes { 0 };
std::atomic<uint64_t> g_elided_copies { 0 };
std::atomic<int64_t>  g_pinned_bytes { 0 };

} // namespace

void wallpaper::render::SetSceneOptimizationEnabled(bool enabled)
{
    g_scene_optimization_enabled.store(enabled, std::memory_order_relaxed);
}

bool wallpaper::render::SceneOptimizationEnabled()
{
    return g_scene_optimization_enabled.load(std::memory_order_relaxed);
}

void wallpaper::render::RecordSceneOptimizationFrame(uint64_t executed_passes,
                                                     uint64_t skipped_passes)
{
    g_executed_passes.fetch_add(executed_passes, std::memory_order_relaxed);
    g_skipped_passes.fetch_add(skipped_passes, std::memory_order_relaxed);
}

void wallpaper::render::RecordElidedCopies(uint64_t count)
{
    g_elided_copies.fetch_add(count, std::memory_order_relaxed);
}

void wallpaper::render::AdjustSceneOptimizationPinnedBytes(int64_t delta)
{
    g_pinned_bytes.fetch_add(delta, std::memory_order_relaxed);
}

SceneOptimizationTotals wallpaper::render::CurrentSceneOptimizationTotals()
{
    const auto pinned = g_pinned_bytes.load(std::memory_order_relaxed);
    return SceneOptimizationTotals {
        .executed_passes = g_executed_passes.load(std::memory_order_relaxed),
        .skipped_passes  = g_skipped_passes.load(std::memory_order_relaxed),
        .elided_copies   = g_elided_copies.load(std::memory_order_relaxed),
        .pinned_bytes    = pinned > 0 ? static_cast<uint64_t>(pinned) : 0ULL,
    };
}

void wallpaper::render::ResetSceneOptimizationTotalsForTesting()
{
    g_executed_passes.store(0, std::memory_order_relaxed);
    g_skipped_passes.store(0, std::memory_order_relaxed);
    g_elided_copies.store(0, std::memory_order_relaxed);
    g_pinned_bytes.store(0, std::memory_order_relaxed);
}
