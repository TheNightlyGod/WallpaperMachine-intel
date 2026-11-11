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
    /// Advances the sheet by `newtime` and shows its frame: the sheet follows
    /// its own clock.
    const SpriteFrame& GetAnimateFrame(double newtime) { return Present(newtime, false, 0.0); }
    /// What a script's texture animation does to the sheet (Wallpaper Engine's
    /// TextureAnimation object, `we_ss_reg_TextureAnimation` 0x1402131A0).
    /// The sheet's own clock (the texture's frame, texture+208 +156) always
    /// runs by the frame time. While a script holds the layer `detached` (+72)
    /// the layer shows a frame of its own (+232) that advances by
    /// `detached_step` instead; otherwise it shows the clock's frame.
    const SpriteFrame& Present(double frame_time, bool detached, double detached_step) {
        if (m_frames.empty()) return Neutral();
        Elapse(m_clock, frame_time);
        if (! detached) {
            m_shown = m_clock;
        } else {
            Elapse(m_shown, detached_step);
        }
        return m_frames[(usize)m_shown.frame];
    }
    /// A script command, applied once per `serial`: `copy_clock` takes the
    /// clock's frame (and the time left on it) as the layer's own -- `pause()`
    /// and a `rate` other than one on a sheet that still follows its clock,
    /// 0x1401FA340 / 0x1401FA4A0 -- else the layer's own frame becomes `frame`
    /// (`setFrame`, `stop`; 0x1401FA400 / 0x1401FA3A0). A frame outside the
    /// table shows the nearest one.
    void Command(uint64_t serial, bool copy_clock, int64_t frame) {
        if (serial == m_command || m_frames.empty()) return;
        m_command = serial;
        if (copy_clock) {
            m_shown = m_clock;
            return;
        }
        const auto last = static_cast<int64_t>(m_frames.size() - 1);
        m_shown.frame   = (idx)std::clamp<int64_t>(frame, 0, last);
        m_shown.remain  = FrameDuration(m_frames[(usize)m_shown.frame]);
    }
    const auto& GetCurFrame() const { return m_frames.at((usize)m_shown.frame); }
    /// One frame by index, for callers that must know every image a sheet can
    /// reach before the animation reaches it -- a renderer that uploads the
    /// sheets up front cannot wait to be surprised mid-playback.
    const SpriteFrame& FrameAt(usize index) const { return m_frames.at(index); }
    /// Index of the frame `GetCurFrame` returns.
    idx CurFrameIndex() const { return m_shown.frame; }
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
    struct Cursor {
        idx    frame { 0 };
        double remain { 0 };
    };
    // Moves to the next frame (the last wraps to the first) and returns its duration.
    double StepForward(Cursor& at) const {
        at.frame = (at.frame + 1) % (idx)m_frames.size();
        return FrameDuration(m_frames[(usize)at.frame]);
    }
    // The time left is a credit; only what the credit does not cover is owed,
    // and the owed time is paid by moving on. Nothing that is not a positive,
    // finite time moves the sheet.
    void Elapse(Cursor& at, double seconds) const {
        if (! (std::isfinite(seconds) && seconds > 0.0)) return;
        const double owed = seconds - at.remain;
        if (owed <= 0.0) {
            at.remain -= seconds;
            return;
        }
        if (m_cycle <= 0.0) {
            // Nothing is timed: each tick is one step.
            StepForward(at);
            at.remain = 0.0;
            return;
        }
        at.remain = -PayOff(at, owed);
    }
    // Moves on until `debt` is paid and returns what is still owed (at most 0 or a
    // rounding sliver). Whole cycles come back to the same frame, so they are not
    // walked: one pass over the frames bounds the work.
    double PayOff(Cursor& at, double debt) const {
        if (debt > m_cycle) debt = std::fmod(debt, m_cycle);
        for (usize hops = m_frames.size(); hops > 0 && debt > 0.0; --hops) debt -= StepForward(at);
        return debt;
    }

    Cursor   m_clock;
    Cursor   m_shown;
    uint64_t m_command { 0 };
    double   m_cycle { 0 };

    std::vector<SpriteFrame> m_frames;
};
} // namespace wallpaper
