// A streaming sample-rate converter: a polyphase windowed-sinc filter (a sinc
// low-pass cut at 97 percent of the output Nyquist frequency or at the input's,
// whichever is lower, shaped by a Kaiser window with beta 9, 32 taps per output
// sample when raising the rate and proportionally more when lowering it). Output frame n is the filtered signal
// at input time n * inRate / outRate, so the first output frame lines up with
// the first input frame and nothing is delayed; before the first and after the
// last input frame the signal is silence.
//
// The ratio is reduced to lowest terms. When the reduced output rate is at most
// 1024 the filter phases are exact (44.1 kHz to 48 kHz is 160 phases);
// otherwise 1024 phases are interpolated linearly. Positions are tracked as
// integers, so nothing drifts over a long sound.
//
// A whole pass of `n` input frames produces exactly ceil(n * outRate / inRate)
// frames once `flush` has been called.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wallpaper::sound
{

class Resampler {
public:
    /// Lowering the rate stretches the filter by the ratio, and with it its table;
    /// a ratio past this (the input rate more than about 62 times the output's)
    /// is not built. Both rates must be non-zero.
    static bool Supports(std::uint32_t inRate, std::uint32_t outRate);

    /// The constructor clamps an unsupported ratio instead of growing the table
    /// without bound, so a sound is never resampled at a wrong rate by accident:
    /// callers check `Supports` first.
    Resampler(std::uint32_t channels, std::uint32_t inRate, std::uint32_t outRate);

    std::uint32_t channels() const { return m_channels; }

    /// Starts a new pass: forgets the input and the position.
    void reset();

    /// Takes `frames` interleaved input frames and appends the output frames
    /// that can be finished with the input so far to `out`.
    void push(const float* in, std::size_t frames, std::vector<float>& out);

    /// Ends the pass: appends the rest of the output, treating the input as
    /// silent from here on. The next `push` starts a new pass.
    void flush(std::vector<float>& out);

private:
    void produce(std::uint64_t available_through, std::vector<float>& out);
    void emit(std::vector<float>& out);
    void trim();

    std::uint32_t m_channels;
    std::uint64_t m_rin;  // reduced input rate
    std::uint64_t m_rout; // reduced output rate
    std::size_t   m_half; // taps on each side of the position
    std::size_t   m_taps; // 2 * m_half
    std::size_t   m_phases;
    bool          m_interpolate;
    std::vector<float> m_table; // (m_phases + 1) rows of m_taps

    // State of the pass in progress.
    std::vector<float> m_buffer;  // interleaved frames from absolute index m_base
    std::int64_t       m_base { 0 };
    std::uint64_t      m_in_frames { 0 };  // frames pushed so far
    std::int64_t       m_index { 0 };      // input frame at or before the next output position
    std::uint64_t      m_numerator { 0 };  // position fraction, in units of 1/m_rout
    std::uint64_t      m_out_frames { 0 }; // frames produced so far
};

} // namespace wallpaper::sound
