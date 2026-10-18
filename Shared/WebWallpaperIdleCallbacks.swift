import Foundation

/// `requestIdleCallback` and `cancelIdleCallback` for a WebKit that lacks them.
///
/// Wallpaper Engine runs a web wallpaper in Chromium, which has had both for years, so pages
/// written for it call `window.requestIdleCallback` without checking for it. WebKit on macOS
/// does not define it, and the call throws a `TypeError`: a visualizer that asks for an idle
/// callback just before it requests its first animation frame stops right there, drawing
/// nothing while its audio listener keeps receiving the spectrum.
///
/// The script this holds runs at document start in every frame, as Chromium has the API in
/// every frame, and does nothing where the browser already has a `requestIdleCallback`. It
/// follows the specification's model of idle periods with Chromium's longest period, 50 ms,
/// the one Chromium gives a page that has no frame pending:
///
/// - A callback runs in the next idle period, which starts on a timer once the previous
///   period has ended; callbacks queued from inside a period wait for the next one, so a
///   callback that requests itself again runs at most once per period (20 times a second)
///   rather than at the timer clamp.
/// - `timeRemaining()` counts down to the end of the period; when it reaches zero the
///   callbacks still waiting move to the next period.
/// - A `timeout` runs a callback that is still waiting with `didTimeout` true and no time
///   remaining. A callback that throws is reported and the others still run.
///
/// Chromium ends a period at the next frame when the page is animating; this script cannot
/// see frames, so an animating page's callbacks get the full 50 ms too.
enum WebWallpaperIdleCallbacks {
  static let script = """
    (() => {
      if (typeof window.requestIdleCallback === "function") return;
      const IDLE_PERIOD_MS = 50;
      const setTimer = window.setTimeout.bind(window);
      const clearTimer = window.clearTimeout.bind(window);
      const now = () => performance.now();
      const report = error => {
        try { window.reportError(error); } catch (unavailable) { setTimer(() => { throw error; }, 0); }
      };
      // Waiting callbacks by handle, in the order they were requested.
      const waiting = new Map();
      let lastHandle = 0;
      let periodTimer = null;
      let periodEnd = 0;
      const invoke = (callback, deadline, didTimeout) => {
        const idleDeadline = Object.freeze({
          didTimeout,
          timeRemaining: () => Math.max(0, deadline - now()),
        });
        try { callback(idleDeadline); } catch (error) { report(error); }
      };
      const runPeriod = () => {
        periodTimer = null;
        periodEnd = now() + IDLE_PERIOD_MS;
        // Only what was waiting when the period began runs in it.
        for (const handle of Array.from(waiting.keys())) {
          if (now() >= periodEnd) break;
          const entry = waiting.get(handle);
          if (!entry) continue;
          waiting.delete(handle);
          if (entry.timer !== null) clearTimer(entry.timer);
          invoke(entry.callback, periodEnd, false);
        }
        schedulePeriod();
      };
      const schedulePeriod = () => {
        if (periodTimer !== null || waiting.size === 0) return;
        periodTimer = setTimer(runPeriod, Math.max(0, periodEnd - now()));
      };
      window.requestIdleCallback = function requestIdleCallback(callback, options) {
        if (typeof callback !== "function") {
          throw new TypeError("requestIdleCallback: parameter 1 is not of type 'Function'.");
        }
        const handle = ++lastHandle;
        const timeout = Number(options && options.timeout);
        const entry = { callback, timer: null };
        if (timeout > 0) {
          entry.timer = setTimer(() => {
            if (waiting.get(handle) !== entry) return;
            waiting.delete(handle);
            invoke(callback, 0, true);
          }, timeout);
        }
        waiting.set(handle, entry);
        schedulePeriod();
        return handle;
      };
      window.cancelIdleCallback = function cancelIdleCallback(handle) {
        const entry = waiting.get(Number(handle));
        if (!entry) return;
        waiting.delete(Number(handle));
        if (entry.timer !== null) clearTimer(entry.timer);
      };
    })()
    """
}
