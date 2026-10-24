#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace wallpaper
{
namespace render
{

/// Why a render target's pixels cannot be reused from the previous frame.
///
/// Every reason is an independent bit so a diagnostic can say which input made
/// a subgraph dynamic rather than only that it was not cached. `None` alone is
/// not sufficient for reuse: the target must also hold a pinned allocation,
/// because the render-target pool aliases unpinned images to other keys.
enum class DynamicReason : uint32_t
{
    None = 0,
    /// Reflection reported a uniform whose value advances every frame.
    TimeUniform = 1u << 0,
    AudioUniform = 1u << 1,
    PointerUniform = 1u << 2,
    /// Skeletal or puppet transforms written per frame.
    BoneUniform = 1u << 3,
    /// A decoded video frame is bound as an input texture.
    VideoInput = 1u << 4,
    /// Vertex or index data is re-uploaded per frame by something that
    /// advances on its own.
    DynamicMesh = 1u << 5,
    /// A sprite sheet with more than one frame.
    AnimatedSprite = 1u << 6,
    /// An input image the runtime may swap underneath the pass.
    RuntimeImage = 1u << 7,
    /// The pass reads a target it also writes, directly or through a cycle.
    Feedback = 1u << 8,
    /// An input this analysis cannot account for.
    UnknownInput = 1u << 9,
    /// Vertex data the runtime rewrites when an event re-lays the mesh out,
    /// and leaves alone in between -- a text card.
    ///
    /// Reported separately from `DynamicMesh` because the two answer different
    /// questions with the same fact. For pixel reuse they are identical: a
    /// target drawn from either is never cacheable, because the upload happens
    /// only for a pass that executes. For whole-scene idling they are
    /// opposites, which is why the scene-level mapping carries one and not the
    /// other.
    EventMesh = 1u << 10,
};

constexpr uint32_t operator|(DynamicReason lhs, DynamicReason rhs)
{
    return static_cast<uint32_t>(lhs) | static_cast<uint32_t>(rhs);
}

constexpr uint32_t operator|(uint32_t lhs, DynamicReason rhs)
{
    return lhs | static_cast<uint32_t>(rhs);
}

constexpr uint32_t& operator|=(uint32_t& lhs, DynamicReason rhs)
{
    lhs = lhs | static_cast<uint32_t>(rhs);
    return lhs;
}

constexpr bool operator&(uint32_t lhs, DynamicReason rhs)
{
    return (lhs & static_cast<uint32_t>(rhs)) != 0;
}

/// Compile-time shape of one pass in the linearised pass list.
struct StaticPassDesc
{
    /// Render-target key the pass writes. Empty means the pass produces
    /// nothing this cache can reason about, so it always executes.
    std::string target;
    /// Render-target keys the pass reads. Imported images are deliberately
    /// absent: they never change once uploaded, so they impose no dependency.
    std::vector<std::string> inputs;
    uint32_t dynamic_reasons { 0 };
};

/// Per-frame varying state of one pass, reduced to a single value.
///
/// The hash must cover every input that can change the pass's output without
/// changing the graph: node and parent transforms, the camera, material
/// constants, mesh revision, sprite frame and target extent.
struct StaticPassSample
{
    uint64_t hash { 0 };
    bool visible { true };
};

/// Reuses the previous frame's pixels for render targets whose inputs have not
/// changed.
///
/// The unit of reuse is a render target, never an individual pass. Passes that
/// write one target are batched into a single render pass whose first entry may
/// carry a clear, so skipping part of a batch would either lose a draw or
/// composite one twice. All writers of a target are therefore skipped together
/// or not at all.
class StaticSubgraphCache {
public:
    struct Stats
    {
        uint64_t executed_passes { 0 };
        uint64_t skipped_passes { 0 };
        uint32_t cacheable_targets { 0 };
        uint32_t pinned_targets { 0 };
        uint64_t pinned_bytes { 0 };
    };

    void Reset();

    /// Builds the target table from the linearised pass list. Passes must be in
    /// execution order.
    void Compile(std::span<const StaticPassDesc> passes);

    std::size_t TargetCount() const { return m_targets.size(); }
    const std::string& TargetKey(std::size_t index) const { return m_targets[index].key; }
    bool TargetCacheable(std::size_t index) const { return m_targets[index].cacheable; }
    uint32_t TargetDynamicReasons(std::size_t index) const
    {
        return m_targets[index].dynamic_reasons;
    }

    /// Records that the caller secured an exclusive allocation for this target.
    /// A cacheable target that is not pinned is never skipped, because the
    /// render-target pool may hand its image to another key.
    void SetTargetPinned(std::size_t index, bool pinned, uint64_t bytes);

    /// Decides which passes may be skipped this frame. `out_skip` must have one
    /// byte per pass, 1 meaning skip; entries are overwritten, never
    /// accumulated. A byte rather than `bool` because `std::vector<bool>`
    /// cannot back a span.
    void Plan(std::span<const StaticPassSample> samples, std::span<uint8_t> out_skip);

    /// Whether `Plan` reads this pass's sample. Only the writers of a
    /// cacheable target fold into a signature; every other pass executes
    /// whatever its sample says, so a caller need not take one for it.
    bool PassSampled(std::size_t pass) const
    {
        return pass < m_pass_target.size() && m_pass_target[pass] != kNoTarget &&
               m_targets[m_pass_target[pass]].cacheable;
    }

    /// Drops every cached result without losing the compiled analysis. Used
    /// when the pixels behind the targets are no longer trustworthy.
    void InvalidateAll();

    const Stats& stats() const { return m_stats; }

private:
    struct Target
    {
        std::string key;
        std::vector<std::size_t> writers;
        /// Indices into `m_targets`, deduplicated.
        std::vector<std::size_t> inputs;
        uint32_t dynamic_reasons { 0 };
        bool cacheable { false };
        bool pinned { false };
        bool rendered_once { false };
        uint64_t pinned_bytes { 0 };
        uint64_t last_signature { 0 };
        uint64_t frame_signature { 0 };
    };

    std::size_t targetIndex(const std::string& key) const;
    /// Clears `cacheable` for every target reachable from a dynamic one, and
    /// for every target caught in a dependency cycle.
    void propagateDynamic();
    void orderTargets();

    std::vector<Target> m_targets;
    /// Pass index to target index, or `kNoTarget`.
    std::vector<std::size_t> m_pass_target;
    /// Cacheable targets in dependency order, inputs first.
    std::vector<std::size_t> m_plan_order;
    Stats m_stats;

    static constexpr std::size_t kNoTarget = static_cast<std::size_t>(-1);
};

/// Stable 64-bit mix used to fold per-frame values into a pass sample. Exposed
/// so the renderer and the tests agree on one definition.
uint64_t StaticHashMix(uint64_t seed, uint64_t value);
uint64_t StaticHashBytes(uint64_t seed, const void* data, std::size_t size);

/// Process-wide switch for static reuse and copy elimination. On by default,
/// so turning it off is what needs a deliberate act, not turning it on.
void SetSceneOptimizationEnabled(bool enabled);
bool SceneOptimizationEnabled();

/// Totals across every scene in this process. Pass counts are monotonic since
/// process start; `pinned_bytes` is the current estimate of what the pinned
/// targets occupy, derived from extent and mip count rather than queried from
/// the allocator.
struct SceneOptimizationTotals
{
    uint64_t executed_passes { 0 };
    uint64_t skipped_passes { 0 };
    uint64_t elided_copies { 0 };
    uint64_t pinned_bytes { 0 };
};

void RecordSceneOptimizationFrame(uint64_t executed_passes, uint64_t skipped_passes);
void RecordElidedCopies(uint64_t count);
void AdjustSceneOptimizationPinnedBytes(int64_t delta);
SceneOptimizationTotals CurrentSceneOptimizationTotals();
void ResetSceneOptimizationTotalsForTesting();

} // namespace render
} // namespace wallpaper
