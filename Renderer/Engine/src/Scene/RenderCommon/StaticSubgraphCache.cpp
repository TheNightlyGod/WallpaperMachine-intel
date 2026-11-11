#include "RenderCommon/StaticSubgraphCache.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>

using namespace wallpaper::render;

namespace
{

constexpr uint64_t kFnvOffset = 1469598103934665603ULL;

/// One step of the sample hash: a 64-bit word folded into the state, then the
/// SplitMix64 finalizer (Stafford's Mix13). The finalizer is a bijection, so a
/// step is one-to-one in the state for a given word and in the word for a given
/// state: two streams of words that differ in exactly one word always end
/// differently, and every bit of the result depends on every bit of both.
/// Eight bytes cost two multiplies where folding them byte by byte cost eight.
inline uint64_t HashStep(uint64_t state, uint64_t word)
{
    uint64_t x = state ^ word;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

} // namespace

uint64_t wallpaper::render::StaticHashMix(uint64_t seed, uint64_t value)
{
    // Chained, never combined symmetrically, so two different orderings of the
    // same values do not collide, which matters because a pass sample is the
    // concatenation of several unrelated quantities.
    return HashStep(seed, value);
}

uint64_t wallpaper::render::StaticHashBytes(uint64_t seed, const void* data, std::size_t size)
{
    const auto* bytes = static_cast<const unsigned char*>(data);
    std::size_t at    = 0;
    for (; at + sizeof(uint64_t) <= size; at += sizeof(uint64_t)) {
        uint64_t word;
        std::memcpy(&word, bytes + at, sizeof(word));
        seed = HashStep(seed, word);
    }
    if (at < size) {
        uint64_t word = 0;
        std::memcpy(&word, bytes + at, size - at);
        seed = HashStep(seed, word);
    }
    // The length last: a zero-padded tail is not a shorter run of the same
    // bytes, and two runs split at another place are not the same two runs.
    return HashStep(seed, static_cast<uint64_t>(size));
}

void StaticSubgraphCache::Reset()
{
    m_targets.clear();
    m_signature_groups.clear();
    m_pass_target.clear();
    m_pass_inputs.clear();
    m_execution_rank.clear();
    m_plan_order.clear();
    m_stats = Stats {};
    m_has_execution_order = false;
    m_pending_delayed_inputs = false;
    m_has_delayed_inputs = false;
    m_has_feedback_cycles = false;
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

    m_pass_inputs.resize(passes.size());
    m_execution_rank.resize(passes.size());
    for (std::size_t i = 0; i < passes.size(); ++i) m_execution_rank[i] = i;
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
        const auto add_input = [&](const std::string& key, bool previous) {
            const auto source = targetIndex(key);
            // Imported images have no writer and remain immutable.
            if (source == kNoTarget) return;
            auto& inputs = m_targets[target].inputs;
            auto found = std::find_if(inputs.begin(), inputs.end(),
                                     [source](const auto& input) { return input.target == source; });
            if (found == inputs.end()) {
                inputs.push_back({ source });
                found = inputs.end() - 1;
            }
            m_pass_inputs[pass].push_back({source,
                static_cast<std::size_t>(found - inputs.begin()), previous});
        };
        for (const auto& input : passes[pass].inputs) add_input(input, false);
        for (const auto& input : passes[pass].previous_inputs) add_input(input, true);
    }

    // Reuse remains conservative over the full target graph. Signature groups
    // separately let a delayed reader track a source whose ordinary within-frame
    // scene snapshots form a target-level cycle.
    buildSignatureGroups();
    for (auto& target : m_targets) {
        if (target.cyclic) target.dynamic_reasons |= DynamicReason::Feedback;
        target.cacheable = target.dynamic_reasons == 0;
    }
    propagateDynamic();
    updateInputVersions();

    for (const auto& target : m_targets)
        if (target.cacheable) ++m_stats.cacheable_targets;
}

void StaticSubgraphCache::SetPreviousFrameInputs(
    std::span<const StaticPreviousFrameInput> inputs)
{
    for (auto& uses : m_pass_inputs)
        for (auto& use : uses) use.previous = false;
    for (const auto& input : inputs) {
        if (input.pass >= m_pass_inputs.size()) continue;
        for (auto& use : m_pass_inputs[input.pass])
            if (m_targets[use.source].key == input.key) use.previous = true;
    }
    updateInputVersions();
}

void StaticSubgraphCache::SetExecutionOrder(std::span<const std::size_t> execution_order)
{
    if (execution_order.size() != m_pass_target.size()) return;
    std::vector<std::size_t> rank(execution_order.size(), kNoTarget);
    for (std::size_t i = 0; i < execution_order.size(); ++i) {
        if (execution_order[i] >= rank.size() || rank[execution_order[i]] != kNoTarget) return;
        rank[execution_order[i]] = i;
    }
    m_execution_rank = std::move(rank);
    m_has_execution_order = true;
    for (auto& target : m_targets) {
        std::sort(target.writers.begin(), target.writers.end(),
                  [&](auto lhs, auto rhs) { return m_execution_rank[lhs] < m_execution_rank[rhs]; });
    }
    for (std::size_t pass = 0; pass < m_pass_inputs.size(); ++pass)
        for (auto& use : m_pass_inputs[pass])
            use.previous = m_execution_rank[pass] <
                           m_execution_rank[m_targets[use.source].writers.front()];
    updateInputVersions();
}

void StaticSubgraphCache::buildSignatureGroups()
{
    // Strongly connected components are a compile-time plan. They never require
    // a graph traversal while sampling a frame.
    std::vector<std::size_t> index(m_targets.size(), kNoTarget);
    std::vector<std::size_t> low(m_targets.size(), kNoTarget);
    std::vector<std::size_t> stack;
    std::vector<uint8_t> stacked(m_targets.size(), 0);
    std::size_t next = 0;
    const auto visit = [&](auto&& self, std::size_t target) -> void {
        index[target] = low[target] = next++;
        stack.push_back(target);
        stacked[target] = 1;
        for (const auto& input : m_targets[target].inputs) {
            if (index[input.target] == kNoTarget) {
                self(self, input.target);
                low[target] = std::min(low[target], low[input.target]);
            } else if (stacked[input.target] != 0) {
                low[target] = std::min(low[target], index[input.target]);
            }
        }
        if (low[target] != index[target]) return;
        SignatureGroup group;
        for (;;) {
            const auto member = stack.back();
            stack.pop_back();
            stacked[member] = 0;
            m_targets[member].signature_group = m_signature_groups.size();
            group.targets.push_back(member);
            if (member == target) break;
        }
        std::sort(group.targets.begin(), group.targets.end());
        const bool cyclic = group.targets.size() > 1 || std::any_of(
            m_targets[target].inputs.begin(), m_targets[target].inputs.end(),
            [target](const auto& input) { return input.target == target; });
        for (const auto member : group.targets) m_targets[member].cyclic = cyclic;
        m_signature_groups.push_back(std::move(group));
    };
    for (std::size_t i = 0; i < m_targets.size(); ++i)
        if (index[i] == kNoTarget) visit(visit, i);
}

void StaticSubgraphCache::updateInputVersions()
{
    m_has_delayed_inputs = false;
    m_has_feedback_cycles = false;
    for (auto& target : m_targets) {
        target.sampled = target.cacheable;
        target.previous_input = false;
        for (auto& input : target.inputs) input.current = input.previous = false;
    }
    for (auto& group : m_signature_groups) group.sampled = group.feedback = false;
    for (std::size_t pass = 0; pass < m_pass_inputs.size(); ++pass) {
        if (m_pass_target[pass] == kNoTarget) continue;
        auto& target = m_targets[m_pass_target[pass]];
        for (const auto& use : m_pass_inputs[pass]) {
            auto& input = target.inputs[use.edge];
            if (use.previous) {
                input.previous = true;
                m_has_delayed_inputs = true;
                auto& source = m_targets[use.source];
                source.previous_input = true;
                if (source.signature_group == target.signature_group) {
                    m_signature_groups[target.signature_group].feedback = true;
                    m_has_feedback_cycles = true;
                }
            } else {
                input.current = true;
            }
        }
    }
    // Current-frame snapshot cycles cannot reuse target pixels, but their
    // writers and external inputs completely describe their result. Track that
    // finite version when a delayed reader needs to catch up after an event.
    for (auto& target : m_targets) {
        for (const auto& input : target.inputs) {
            if (!input.previous) continue;
            if (!m_signature_groups[target.signature_group].feedback) target.sampled = true;
            auto& source = m_targets[input.target];
            if (!m_signature_groups[source.signature_group].feedback) source.sampled = true;
        }
    }
    bool changed = true;
    while (changed) {
        changed = false;
        for (auto& target : m_targets) {
            if (!target.sampled) continue;
            auto& group = m_signature_groups[target.signature_group];
            group.sampled = true;
            for (const auto member : group.targets) {
                if (!m_targets[member].sampled) {
                    m_targets[member].sampled = true;
                    changed = true;
                }
            }
            for (const auto& input : target.inputs) {
                auto& source = m_targets[input.target];
                if (!source.sampled && !m_signature_groups[source.signature_group].feedback) {
                    source.sampled = true;
                    changed = true;
                }
            }
        }
    }
    orderTargets();
}

void StaticSubgraphCache::propagateDynamic()
{
    bool changed = true;
    while (changed) {
        changed = false;
        for (auto& target : m_targets) {
            if (!target.cacheable) continue;
            for (const auto& input : target.inputs) {
                if (m_targets[input.target].cacheable) continue;
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
    m_plan_order.clear();
    std::vector<bool> placed(m_signature_groups.size(), false);
    bool progressed = true;
    while (progressed) {
        progressed = false;
        for (std::size_t i = 0; i < m_signature_groups.size(); ++i) {
            const auto& group = m_signature_groups[i];
            if (placed[i] || !group.sampled) continue;
            bool ready = true;
            for (const auto target : group.targets) {
                for (const auto& input : m_targets[target].inputs) {
                    const auto source = m_targets[input.target].signature_group;
                    if (input.current && source != i && m_signature_groups[source].sampled &&
                        !placed[source]) ready = false;
                }
            }
            if (!ready) continue;
            placed[i] = true;
            m_plan_order.push_back(i);
            progressed = true;
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
    m_pending_delayed_inputs = false;
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

    for (const auto group_index : m_plan_order) {
        const auto& group = m_signature_groups[group_index];
        uint64_t signature = kFnvOffset;
        const bool compound = group.targets.size() > 1;
        for (const auto index : group.targets) {
            const auto& target = m_targets[index];
            if (compound) signature = StaticHashMix(signature, index);
            for (const auto writer : target.writers) {
                if (writer >= samples.size()) continue;
                if (compound) {
                    signature = StaticHashMix(signature, m_execution_rank[writer]);
                }
                if (m_has_execution_order && target.writers.size() > 1) {
                    // Copy/clear writers can have identical samples. Their
                    // stable IDs preserve which writer ran last without adding
                    // hashing to graphs whose order never changes.
                    signature = StaticHashMix(signature, writer);
                }
                signature = StaticHashMix(signature, samples[writer].hash);
                signature = StaticHashMix(signature, samples[writer].visible ? 1u : 0u);
            }
            for (const auto& input : target.inputs) {
                const auto& source = m_targets[input.target];
                if (source.signature_group == group_index) continue;
                if (compound) signature = StaticHashMix(signature, input.target);
                // Version tags invalidate a consumer when its read timing
                // changes even if the source currently has identical pixels.
                if (input.current) {
                    signature = StaticHashMix(signature, source.frame_signature);
                }
                if (input.previous) {
                    signature = StaticHashMix(signature, 2u);
                    signature = StaticHashMix(signature, source.last_signature);
                }
            }
        }
        for (const auto index : group.targets)
            m_targets[index].frame_signature = compound ? StaticHashMix(signature, index) : signature;
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

    m_pending_delayed_inputs = false;
    if (m_has_delayed_inputs) {
        for (const auto group : m_plan_order) {
            for (const auto index : m_signature_groups[group].targets) {
                for (const auto& input : m_targets[index].inputs) {
                    const auto& source = m_targets[input.target];
                    if (input.previous && source.frame_signature != source.last_signature)
                        m_pending_delayed_inputs = true;
                }
            }
        }
    }
    // Snapshot every sampled source after all consumers have been evaluated.
    // Unpinned sources are redrawn, but their produced version is still needed
    // by delayed inputs on the following frame.
    for (const auto group : m_plan_order) {
        for (const auto index : m_signature_groups[group].targets) {
            auto& target = m_targets[index];
            target.last_signature = target.frame_signature;
            if (target.pinned) target.rendered_once = true;
        }
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
