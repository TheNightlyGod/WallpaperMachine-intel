// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#pragma once
#include <cstdint>
#include <vector>
#include <iostream>
#include <cstdint>
#include <array>
#include <algorithm>
#include <cmath>

#include "Core/Literals.hpp"

namespace wallpaper
{
struct SpriteFrame {
    i32   imageId { 0 };
    float frametime { 0 };
    float x { 0 };
    float y { 0 };
    float width { 1 };
    float height { 1 };
    float rate { 1 };

    std::array<float, 2> xAxis { 1, 0 };
    std::array<float, 2> yAxis { 0, 1 };
};

class SpriteAnimation {
public:
    const auto& GetAnimateFrame(double newtime) {
        // A sheet without frames is not a sprite sheet; there is nothing to step.
        if (m_frames.empty()) return Neutral();
        if (std::isfinite(newtime) && newtime > 0.0) Elapse(newtime);
        return m_frames[(usize)m_curFrame];
    }
    const auto& SetFrame(double frame) {
        if (m_frames.empty()) return Neutral();
        // NaN and anything below the first frame pin frame 0; beyond the table, the last.
        double pinned = std::isnan(frame) ? 0.0 : std::floor(frame);
        pinned        = std::clamp(pinned, 0.0, (double)(m_frames.size() - 1));
        m_curFrame    = (idx)pinned;
        m_remainTime  = FrameDuration(m_frames[(usize)m_curFrame]);
        return m_frames[(usize)m_curFrame];
    }
    const auto& GetCurFrame() const { return m_frames.at((usize)m_curFrame); }
    /// One frame by index, for callers that must know every image a sheet can
    /// reach before the animation reaches it -- a renderer that uploads the
    /// sheets up front cannot wait to be surprised mid-playback.
    const SpriteFrame& FrameAt(usize index) const { return m_frames.at(index); }
    /// Index of the frame `GetCurFrame` returns.
    idx CurFrameIndex() const { return m_curFrame; }
    /// A single-frame sprite never advances, so it does not make its pass
    /// time-varying.
    usize FrameCount() const { return m_frames.size(); }
    void        AppendFrame(const SpriteFrame& frame) {
        m_frames.push_back(frame);
        m_cycle += FrameDuration(frame);
    }

    usize numFrames() const { return m_frames.size(); }

private:
    static const SpriteFrame& Neutral() {
        static const SpriteFrame neutral {};
        return neutral;
    }
    static double FrameDuration(const SpriteFrame& frame) {
        return std::isfinite(frame.frametime) && frame.frametime > 0.0f ? frame.frametime : 0.0;
    }
    // Moves to the next frame (the last wraps to the first) and returns its duration.
    double StepForward() {
        m_curFrame = (m_curFrame + 1) % (idx)m_frames.size();
        return FrameDuration(m_frames[(usize)m_curFrame]);
    }
    // `seconds` is positive and finite. The time left is a credit; only what the
    // credit does not cover is owed, and the owed time is paid by moving on.
    void Elapse(double seconds) {
        const double owed = seconds - m_remainTime;
        if (owed <= 0.0) {
            m_remainTime -= seconds;
            return;
        }
        if (m_cycle <= 0.0) {
            // Nothing is timed: each tick is one step.
            StepForward();
            m_remainTime = 0.0;
            return;
        }
        m_remainTime = -PayOff(owed);
    }
    // Moves on until `debt` is paid and returns what is still owed (at most 0 or a
    // rounding sliver). Whole cycles come back to the same frame, so they are not
    // walked: one pass over the frames bounds the work.
    double PayOff(double debt) {
        if (debt > m_cycle) debt = std::fmod(debt, m_cycle);
        for (usize hops = m_frames.size(); hops > 0 && debt > 0.0; --hops) debt -= StepForward();
        return debt;
    }

    idx    m_curFrame { 0 };
    double m_remainTime { 0 };
    double m_cycle { 0 };

    std::vector<SpriteFrame> m_frames;
};
} // namespace wallpaper
