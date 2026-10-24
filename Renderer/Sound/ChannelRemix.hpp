// Remixing interleaved frames from one channel count to another, the way a
// player's default downmix does: matching positions pass through, the centre
// folds into left and right (and left and right into a mono centre) at minus 3
// dB, surrounds fold forward at minus 3 dB, the low-frequency channel is
// dropped when there is nowhere for it to go, and positions with no source stay
// silent. Layouts are the conventional ones for 1 to 8 channels
// (mono, stereo, 3.0, 4.0, 5.0, 5.1, 6.1, 7.1); beyond that channels are copied
// in order.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wallpaper::sound
{

class ChannelRemix {
public:
    ChannelRemix(std::uint32_t inChannels, std::uint32_t outChannels);

    std::uint32_t inChannels() const { return m_in; }
    std::uint32_t outChannels() const { return m_out; }
    bool          isIdentity() const { return m_in == m_out; }

    /// `in` holds `frames * inChannels` floats and `out` has room for
    /// `frames * outChannels`; they must not overlap.
    void apply(const float* in, float* out, std::size_t frames) const;

    /// The coefficient from input channel `in` to output channel `out`.
    float coefficient(std::uint32_t out, std::uint32_t in) const { return m_matrix[out * m_in + in]; }

private:
    std::uint32_t      m_in;
    std::uint32_t      m_out;
    std::vector<float> m_matrix; // m_out rows of m_in
};

} // namespace wallpaper::sound
