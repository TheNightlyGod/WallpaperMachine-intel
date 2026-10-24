#include "Sound/ChannelRemix.hpp"

#include <algorithm>
#include <array>

namespace wallpaper::sound
{
namespace
{

enum class Position : std::uint8_t {
    FrontLeft,
    FrontRight,
    FrontCenter,
    LowFrequency,
    BackLeft,
    BackRight,
    BackCenter,
    SideLeft,
    SideRight,
};

constexpr float kMinus3dB = 0.70710678118654752f;

/// The channel order of the conventional layout with `channels` channels.
std::vector<Position> Layout(std::uint32_t channels)
{
    using P = Position;
    switch (channels) {
    case 1: return { P::FrontCenter };
    case 2: return { P::FrontLeft, P::FrontRight };
    case 3: return { P::FrontLeft, P::FrontRight, P::FrontCenter };
    case 4: return { P::FrontLeft, P::FrontRight, P::FrontCenter, P::BackCenter };
    case 5: return { P::FrontLeft, P::FrontRight, P::FrontCenter, P::SideLeft, P::SideRight };
    case 6:
        return { P::FrontLeft, P::FrontRight, P::FrontCenter, P::LowFrequency, P::SideLeft, P::SideRight };
    case 7:
        return { P::FrontLeft, P::FrontRight,  P::FrontCenter, P::LowFrequency,
                 P::BackCenter, P::SideLeft,   P::SideRight };
    case 8:
        return { P::FrontLeft, P::FrontRight, P::FrontCenter, P::LowFrequency,
                 P::BackLeft,  P::BackRight,  P::SideLeft,    P::SideRight };
    default: return {};
    }
}

int IndexOf(const std::vector<Position>& layout, Position position)
{
    const auto found = std::find(layout.begin(), layout.end(), position);
    return found == layout.end() ? -1 : static_cast<int>(found - layout.begin());
}

} // namespace

ChannelRemix::ChannelRemix(std::uint32_t inChannels, std::uint32_t outChannels)
    : m_in(inChannels), m_out(outChannels), m_matrix(static_cast<std::size_t>(inChannels) * outChannels, 0.0f)
{
    const auto in_layout  = Layout(inChannels);
    const auto out_layout = Layout(outChannels);
    const auto set        = [&](int out, std::uint32_t in, float gain) {
        if (out >= 0) m_matrix[static_cast<std::size_t>(out) * m_in + in] += gain;
    };

    if (in_layout.empty() || out_layout.empty() || inChannels == outChannels) {
        // No known layout on one side, or nothing to do: channel i to channel i.
        for (std::uint32_t channel = 0; channel < std::min(inChannels, outChannels); ++channel) {
            set(static_cast<int>(channel), channel, 1.0f);
        }
        return;
    }

    using P = Position;
    const int out_fl = IndexOf(out_layout, P::FrontLeft);
    const int out_fr = IndexOf(out_layout, P::FrontRight);
    const int out_fc = IndexOf(out_layout, P::FrontCenter);
    const bool out_stereo = out_fl >= 0 && out_fr >= 0;

    for (std::uint32_t in = 0; in < inChannels; ++in) {
        const P position = in_layout[in];
        if (const int same = IndexOf(out_layout, position); same >= 0) {
            set(same, in, 1.0f);
            continue;
        }
        switch (position) {
        case P::FrontCenter:
            if (out_stereo) {
                set(out_fl, in, kMinus3dB);
                set(out_fr, in, kMinus3dB);
            }
            break;
        case P::FrontLeft:
        case P::FrontRight:
            // Only a layout with no left and right (mono) lacks them.
            set(out_fc, in, kMinus3dB);
            break;
        case P::LowFrequency: break;
        case P::BackLeft:
        case P::BackRight:
        case P::SideLeft:
        case P::SideRight: {
            const bool left = position == P::BackLeft || position == P::SideLeft;
            // The other surround pair, when the output has it, takes it whole.
            const P other = position == P::BackLeft    ? P::SideLeft
                            : position == P::BackRight ? P::SideRight
                            : position == P::SideLeft  ? P::BackLeft
                                                       : P::BackRight;
            if (const int pair = IndexOf(out_layout, other); pair >= 0) {
                set(pair, in, 1.0f);
            } else if (out_stereo) {
                set(left ? out_fl : out_fr, in, kMinus3dB);
            } else {
                set(out_fc, in, kMinus3dB * kMinus3dB);
            }
            break;
        }
        case P::BackCenter: {
            const int back_left  = IndexOf(out_layout, P::BackLeft);
            const int back_right = IndexOf(out_layout, P::BackRight);
            const int side_left  = IndexOf(out_layout, P::SideLeft);
            const int side_right = IndexOf(out_layout, P::SideRight);
            const int left       = back_left >= 0 ? back_left : side_left;
            const int right      = back_right >= 0 ? back_right : side_right;
            if (left >= 0 && right >= 0) {
                set(left, in, kMinus3dB);
                set(right, in, kMinus3dB);
            } else if (out_stereo) {
                set(out_fl, in, kMinus3dB * kMinus3dB);
                set(out_fr, in, kMinus3dB * kMinus3dB);
            } else {
                set(out_fc, in, kMinus3dB * kMinus3dB * kMinus3dB);
            }
            break;
        }
        }
    }
}

void ChannelRemix::apply(const float* in, float* out, std::size_t frames) const
{
    if (isIdentity()) {
        std::copy(in, in + frames * m_in, out);
        return;
    }
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const float* source = in + frame * m_in;
        float*       target = out + frame * m_out;
        for (std::uint32_t channel = 0; channel < m_out; ++channel) {
            const float* row = m_matrix.data() + static_cast<std::size_t>(channel) * m_in;
            float        sum = 0.0f;
            for (std::uint32_t input = 0; input < m_in; ++input) sum += row[input] * source[input];
            target[channel] = sum;
        }
    }
}

} // namespace wallpaper::sound
