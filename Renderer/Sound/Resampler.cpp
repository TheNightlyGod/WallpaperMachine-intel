#include "Sound/Resampler.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace wallpaper::sound
{
namespace
{

constexpr double kPi           = 3.14159265358979323846;
constexpr double kCutoff       = 0.97;
constexpr double kKaiserBeta   = 9.0;
constexpr double kHalfTaps     = 16.0;
constexpr std::uint64_t kMaxExactPhases = 1024;
constexpr std::size_t   kInterpolatedPhases = 1024;
// The narrowest low-pass built: a filter of 16 / kMinScale taps on each side, which
// keeps the table near 9 MB however far down a sound's rate would be lowered.
constexpr double        kMinScale = 1.0 / 64.0;

double CutoffScale(std::uint32_t inRate, std::uint32_t outRate)
{
    return std::min(1.0, kCutoff * static_cast<double>(outRate) / static_cast<double>(inRate));
}

/// Modified Bessel function of the first kind, order 0 (power series).
double BesselI0(double x)
{
    double sum  = 1.0;
    double term = 1.0;
    const double quarter = x * x / 4.0;
    for (int k = 1; k < 64; ++k) {
        term *= quarter / (static_cast<double>(k) * static_cast<double>(k));
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

} // namespace

bool Resampler::Supports(std::uint32_t inRate, std::uint32_t outRate)
{
    return inRate != 0 && outRate != 0 && CutoffScale(inRate, outRate) >= kMinScale;
}

Resampler::Resampler(std::uint32_t channels, std::uint32_t inRate, std::uint32_t outRate)
    : m_channels(channels)
{
    const std::uint64_t divisor = std::gcd<std::uint64_t, std::uint64_t>(inRate, outRate);
    m_rin  = inRate / divisor;
    m_rout = outRate / divisor;

    // The low-pass sits at 97 percent of the output Nyquist frequency, but never
    // above the input's: raising the rate keeps the whole input band, lowering it
    // cuts just under the new Nyquist. A lower cutoff stretches the filter so its
    // transition band keeps the same relative width.
    const double scale = std::max(kMinScale, CutoffScale(inRate, outRate));
    const double cutoff = scale;
    m_half = static_cast<std::size_t>(std::ceil(kHalfTaps / scale));
    m_taps = 2 * m_half;

    m_interpolate = m_rout > kMaxExactPhases;
    m_phases      = m_interpolate ? kInterpolatedPhases : static_cast<std::size_t>(m_rout);
    m_table.assign((m_phases + 1) * m_taps, 0.0f);

    const double bessel_beta = BesselI0(kKaiserBeta);
    const double half        = static_cast<double>(m_half);
    for (std::size_t phase = 0; phase <= m_phases; ++phase) {
        // The output sits `fraction` of an input frame after input frame `index`.
        const double fraction = static_cast<double>(phase) / static_cast<double>(m_phases);
        std::vector<double> row(m_taps);
        double sum = 0.0;
        for (std::size_t tap = 0; tap < m_taps; ++tap) {
            // Tap `tap` weighs input frame index + tap - (m_half - 1).
            const double x = static_cast<double>(tap) - (half - 1.0) - fraction;
            const double r = x / half;
            double       value = 0.0;
            if (std::fabs(r) < 1.0) {
                const double arg  = kPi * cutoff * x;
                const double sinc = std::fabs(arg) < 1e-12 ? 1.0 : std::sin(arg) / arg;
                const double window = BesselI0(kKaiserBeta * std::sqrt(1.0 - r * r)) / bessel_beta;
                value = cutoff * sinc * window;
            }
            row[tap] = value;
            sum += value;
        }
        // Unit gain at DC for every phase, so no phase pumps the level.
        for (std::size_t tap = 0; tap < m_taps; ++tap) {
            m_table[phase * m_taps + tap] = static_cast<float>(row[tap] / sum);
        }
    }
    reset();
}

void Resampler::reset()
{
    // Input frames before the first one are silence, kept as real zeros so the
    // filter always reads a full window.
    m_base = -static_cast<std::int64_t>(m_half - 1);
    m_buffer.assign((m_half - 1) * m_channels, 0.0f);
    m_in_frames  = 0;
    m_index      = 0;
    m_numerator  = 0;
    m_out_frames = 0;
}

void Resampler::emit(std::vector<float>& out)
{
    // The window of this output position: frames m_index - (m_half - 1) .. m_index + m_half.
    const std::size_t first = static_cast<std::size_t>(m_index - static_cast<std::int64_t>(m_half - 1) - m_base);
    const float*      window = m_buffer.data() + first * m_channels;

    std::size_t phase = 0;
    float       blend = 0.0f;
    if (m_interpolate) {
        const std::uint64_t scaled = m_numerator * kInterpolatedPhases;
        phase = static_cast<std::size_t>(scaled / m_rout);
        blend = static_cast<float>(static_cast<double>(scaled % m_rout) / static_cast<double>(m_rout));
    } else {
        phase = static_cast<std::size_t>(m_numerator);
    }
    const float* low  = m_table.data() + phase * m_taps;
    const float* high = m_interpolate ? low + m_taps : low;

    const std::size_t at = out.size();
    out.resize(at + m_channels);
    for (std::uint32_t channel = 0; channel < m_channels; ++channel) {
        const float* sample = window + channel;
        float        a      = 0.0f;
        if (!m_interpolate) {
            for (std::size_t tap = 0; tap < m_taps; ++tap) a += low[tap] * sample[tap * m_channels];
            out[at + channel] = a;
            continue;
        }
        float b = 0.0f;
        for (std::size_t tap = 0; tap < m_taps; ++tap) {
            const float value = sample[tap * m_channels];
            a += low[tap] * value;
            b += high[tap] * value;
        }
        out[at + channel] = a + (b - a) * blend;
    }

    // Advance to the next output position: rin/rout input frames further.
    m_numerator += m_rin;
    m_index += static_cast<std::int64_t>(m_numerator / m_rout);
    m_numerator %= m_rout;
    ++m_out_frames;
}

void Resampler::produce(std::uint64_t available_through, std::vector<float>& out)
{
    // An output needs input frames up to m_index + m_half.
    while (static_cast<std::uint64_t>(m_index) + m_half < available_through) emit(out);
}

void Resampler::trim()
{
    // Frames before the next window are no longer needed. The next window can start
    // past everything buffered (a ratio that skips more input frames than one push
    // brought), in which case all of it goes and later input is skipped by position.
    const std::int64_t keep_from = m_index - static_cast<std::int64_t>(m_half - 1);
    const std::int64_t buffered  = static_cast<std::int64_t>(m_buffer.size() / m_channels);
    const std::int64_t drop      = std::min(keep_from - m_base, buffered);
    if (drop >= 4096 || (drop > 0 && drop == buffered)) {
        m_buffer.erase(m_buffer.begin(),
                       m_buffer.begin() + static_cast<std::ptrdiff_t>(static_cast<std::size_t>(drop) * m_channels));
        m_base += drop;
    }
}

void Resampler::push(const float* in, std::size_t frames, std::vector<float>& out)
{
    m_buffer.insert(m_buffer.end(), in, in + frames * m_channels);
    m_in_frames += frames;
    produce(m_in_frames, out);
    trim();
}

void Resampler::flush(std::vector<float>& out)
{
    // Output n exists while n * rin < frames * rout: ceil(frames * rout / rin) frames in all.
    const std::uint64_t total = (m_in_frames * m_rout + m_rin - 1) / m_rin;
    if (m_out_frames < total) {
        // Every remaining position is before the last input frame, so a window of
        // silence after it covers them all.
        m_buffer.insert(m_buffer.end(), (m_half + 1) * m_channels, 0.0f);
        while (m_out_frames < total) emit(out);
    }
    reset();
}

} // namespace wallpaper::sound
