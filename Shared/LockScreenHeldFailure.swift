import Foundation

/// Why a lock-screen or screen-saver surface is not drawing its wallpaper: the scene engine's category
/// and its own explanation (Native Metal is the only renderer it may use), or the reason the extension's
/// own players could not play a video.
///
/// The surface does not hand the wallpaper to another renderer. It keeps what it shows (the last frame,
/// or the project's preview picture when a scene has drawn nothing) and reports this instead, in the log
/// and in the readiness the app reads, so the failure has a reason and nobody mistakes a still picture
/// for a wallpaper that is playing.
struct LockScreenHeldFailure: Equatable {
  /// The engine's `owe_scene_failure_stage`, by name, and `video` for a clip the extension's players
  /// could not play, which the extension itself reports.
  enum Stage: String, Equatable {
    case unsupported, prepare, compile, frame, surface, video
  }

  var stage: Stage
  /// The engine's own English explanation, for diagnostics. Empty when it gave none.
  var reason: String

  /// A plain video the extension's players could not play, with the reason they gave.
  init(video reason: String) {
    stage = .video
    self.reason = reason
  }

  /// From the engine's raw stage and its explanation. Zero is no failure, and a value this build does not
  /// name is not one either: the engine is linked from the same header, so it would be a corrupt reading,
  /// and inventing a stage for it would report a failure nobody can explain.
  init?(rawStage: Int32, reason: String) {
    switch rawStage {
    case 1: stage = .unsupported
    case 2: stage = .prepare
    case 3: stage = .compile
    case 4: stage = .frame
    case 5: stage = .surface
    default: return nil
    }
    self.reason = reason
  }

  /// One stable English fragment for the log: `stage=unsupported reason=…`.
  var logDetail: String {
    reason.isEmpty ? "stage=\(stage.rawValue)" : "stage=\(stage.rawValue) reason=\(reason)"
  }
}
