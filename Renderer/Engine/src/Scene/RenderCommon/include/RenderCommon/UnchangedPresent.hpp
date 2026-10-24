#pragma once

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace wallpaper
{
namespace render
{

/// One video texture's part in a presented frame: the texture, the imported
/// frame object it sampled and that frame's decoded generation.
///
/// The object and the generation are both kept because either can move alone:
/// a re-import of the same generation (a recycled destination after the pool
/// was invalidated) is a different object, and a new generation is a new
/// picture. Either one is a reason to present.
struct PresentedVideoFrame
{
    const void* texture { nullptr };
    const void* frame { nullptr };
    uint64_t    generation { 0 };

    bool operator==(const PresentedVideoFrame&) const = default;
};

/// What the final composition reads besides the scene's own pixels, as raw
/// words compared exactly: output extent and format, the swapchain, the
/// viewport and scissor the scaling layout produced, flip, clear colour.
///
/// Exact comparison, not a hash, because a collision here would leave a stale
/// picture on screen. A key that ran out of room compares unequal to
/// everything, so a caller that adds more than it was sized for loses the skip
/// rather than gaining a false one.
class PresentationKey {
public:
    static constexpr std::size_t kCapacity = 24;

    void Clear() noexcept
    {
        m_size     = 0;
        m_overflow = false;
    }
    void Add(uint64_t value) noexcept
    {
        if (m_size == kCapacity) {
            m_overflow = true;
            return;
        }
        m_words[m_size++] = value;
    }
    void AddFloat(float value) noexcept { Add(static_cast<uint64_t>(std::bit_cast<uint32_t>(value))); }
    void AddDouble(double value) noexcept { Add(std::bit_cast<uint64_t>(value)); }
    void AddPointer(const void* value) noexcept { Add(reinterpret_cast<uintptr_t>(value)); }

    bool operator==(const PresentationKey& other) const noexcept
    {
        if (m_overflow || other.m_overflow || m_size != other.m_size) return false;
        for (std::size_t i = 0; i < m_size; ++i) {
            if (m_words[i] != other.m_words[i]) return false;
        }
        return true;
    }

private:
    std::array<uint64_t, kCapacity> m_words {};
    std::size_t                     m_size { 0 };
    bool                            m_overflow { false };
};

/// Remembers the last frame that actually reached the surface, so that a frame
/// which would put exactly the same pixels back can be left out: no drawable,
/// no submission, no present.
///
/// This is render-result reuse at the scale of the whole surface, gated by the
/// same setting as the per-target reuse it extends. It never decides when the
/// clock ticks and never holds a drawable: the layer simply keeps showing the
/// last frame it was given. The scene's runtime still ticks on every frame; only
/// drawing an identical picture is removed.
///
/// Starts invalid, and every event that could change what a new frame would
/// show without changing the key -- a surface or graph rebuild, a failed frame,
/// a resume, a fill, scale or flip change -- invalidates it, so the next frame
/// presents whatever it would have presented anyway.
class UnchangedPresentGate {
public:
    void Invalidate() noexcept { m_valid = false; }
    [[nodiscard]] bool Valid() const noexcept { return m_valid; }

    /// Whether a frame with this key and these video frames would show exactly
    /// what the last recorded present showed.
    [[nodiscard]] bool Matches(const PresentationKey&             key,
                               std::span<const PresentedVideoFrame> videos) const
    {
        if (! m_valid || ! (key == m_key) || videos.size() != m_videos.size()) return false;
        for (std::size_t i = 0; i < videos.size(); ++i) {
            if (! (videos[i] == m_videos[i])) return false;
        }
        return true;
    }

    /// Called only after a frame was actually presented. Reuses its storage,
    /// so steady playback allocates nothing here.
    void Record(const PresentationKey& key, std::span<const PresentedVideoFrame> videos)
    {
        m_key = key;
        m_videos.assign(videos.begin(), videos.end());
        m_valid = true;
    }

private:
    bool                             m_valid { false };
    PresentationKey                  m_key;
    std::vector<PresentedVideoFrame> m_videos;
};

} // namespace render
} // namespace wallpaper
