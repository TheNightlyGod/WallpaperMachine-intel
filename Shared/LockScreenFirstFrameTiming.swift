import Foundation

/// How long a renderer took to produce its first frame, set against how long
/// WallpaperAgent waits for it.
///
/// WallpaperAgent stops waiting for a first acquire reply after about 31 seconds
/// (observed on macOS 27 in its own log), and the extension gives up at 30. A cold
/// scene start that creeps toward that limit is the case that would need an earlier
/// reply, so the extension and the app record the time and flag a slow one.
enum LockScreenFirstFrameTiming {
  enum Verdict: String, Equatable {
    case normal
    case slow
    case nearLimit = "near limit"
  }

  /// How long WallpaperAgent waits for an acquire reply before it gives up.
  static let agentPatience: Duration = .seconds(31)
  /// From here a first frame is worth remembering.
  static let slowThreshold: Duration = .seconds(10)
  /// From here the agent's limit is close enough to be a risk.
  static let nearLimitThreshold: Duration = .seconds(20)

  static func classify(_ elapsed: Duration) -> Verdict {
    if elapsed >= nearLimitThreshold { return .nearLimit }
    if elapsed >= slowThreshold { return .slow }
    return .normal
  }

  /// Seconds with one decimal and no unit, as logged.
  static func seconds(_ elapsed: Duration) -> String {
    let parts = elapsed.components
    let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    return String(format: "%.1f", value)
  }
}
