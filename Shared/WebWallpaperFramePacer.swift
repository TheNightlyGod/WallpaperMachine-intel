import Foundation

/// The `requestAnimationFrame` pacer behind the frame-rate limit of desktop and
/// preview web pages, kept apart from the rest of the host script so a test can
/// evaluate it against a fake native frame source.
extension WebWallpaperProtocol {
    /// WebKit prefers about 60 rendering updates per second, so a limit at or
    /// above this is left to WebKit entirely: the page's own `requestAnimationFrame`
    /// stays the native one, with its ids, its timestamps and its errors.
    static let framePacingCeiling = 60

    /// Rendering updates per second a page gets: WebKit's cadence near 60, which a
    /// display refreshing more slowly lowers to its own refresh, or the display's
    /// full refresh for a page created to draw at it. A refresh that is not known
    /// (0) counts as the 60 WebKit prefers.
    static func renderRate(displayRefreshRate: Int, rendersAtDisplayRefresh: Bool) -> Int {
        guard displayRefreshRate > 0 else { return framePacingCeiling }
        return rendersAtDisplayRefresh ? displayRefreshRate : min(displayRefreshRate, framePacingCeiling)
    }

    /// The rate the pacer enforces for a descriptor frame rate, or 0 for none.
    /// A frame rate that reaches the page's `renderRate` limits nothing, so the page
    /// keeps its native `requestAnimationFrame`; the pacer itself never works above
    /// `framePacingCeiling`.
    static func frameLimit(forFPS fps: UInt32, renderRate: Int = framePacingCeiling) -> Int {
        let ceiling = max(1, min(renderRate, framePacingCeiling))
        return fps == 0 || Int(fps) >= ceiling ? 0 : Int(fps)
    }

    /// A JavaScript function expression, `(nativeRequest, nativeCancel, reportError)
    /// => { setLimit, isPacing, owns, request, cancel }`.
    ///
    /// A paced callback runs on the first native frame at or after its slot and
    /// receives that frame's own timestamp, so a limit never changes what a page
    /// computes from the timestamp, only how often it is asked to. Slots advance
    /// by one interval from the previous slot rather than from the frame that
    /// served it, so a limit that is not a divisor of the display cadence still
    /// averages its rate (40 on a 60 Hz cadence runs 2 callbacks in 3 frames); a
    /// stall longer than one interval re-anchors instead of catching up in a burst.
    /// At most one native request is outstanding. Paced ids start at 2^30, so a
    /// page that switches between paced and native mode can never cancel the
    /// wrong request.
    static let framePacerSource = """
    (nativeRequest, nativeCancel, reportError) => {
      const ID_BASE = 2 ** 30;
      const CEILING = \(framePacingCeiling);
      let limit = 0;
      let interval = 0;
      let queue = new Map();
      let running = null;
      let nativeHandle = null;
      let next = null;
      let sequence = 0;

      // A frame slightly ahead of its slot is accepted, or a limit whose interval
      // is a hair longer than a whole number of frames would skip a frame every
      // time the cadence jitters.
      const isDue = timestamp => interval === 0 || next === null
        || timestamp >= next - Math.min(interval * 0.15, 4);

      const ensureNative = () => {
        if (nativeHandle === null && queue.size > 0) nativeHandle = nativeRequest(onNative);
      };

      const dispatch = timestamp => {
        if (interval > 0) {
          next = next === null || timestamp - next > interval ? timestamp + interval : next + interval;
        }
        // Callbacks registered while this batch runs belong to a later frame.
        const batch = queue;
        queue = new Map();
        running = batch;
        for (const callback of batch.values()) {
          try { callback(timestamp); } catch (error) { reportError(error); }
        }
        running = null;
      };

      const onNative = timestamp => {
        nativeHandle = null;
        if (queue.size === 0) return;
        if (isDue(timestamp)) dispatch(timestamp);
        ensureNative();
      };

      return {
        // Zero, a negative or non-numeric rate, or one at the ceiling or above,
        // turns pacing off. Callbacks already queued keep draining, at every
        // native frame once the limit is off.
        setLimit(hz) {
          const value = Number.isFinite(hz) && hz >= 1 && hz < CEILING ? hz : 0;
          if (value === limit) return;
          limit = value;
          interval = value > 0 ? 1000 / value : 0;
          next = null;
        },
        isPacing() { return limit > 0; },
        owns(id) { return id >= ID_BASE; },
        request(callback) {
          const id = ID_BASE + (++sequence);
          queue.set(id, callback);
          ensureNative();
          return id;
        },
        cancel(id) {
          // A callback an earlier one in the same batch cancelled is skipped:
          // map iteration does not visit entries deleted before they are reached.
          if (!queue.delete(id) && running) running.delete(id);
          if (queue.size === 0 && nativeHandle !== null) {
            nativeCancel(nativeHandle);
            nativeHandle = null;
          }
        },
      }
    }
    """
}
