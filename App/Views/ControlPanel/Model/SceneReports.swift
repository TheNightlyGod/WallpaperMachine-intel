import Foundation

/// How many pixels a 2D scene is rasterized with, by the names the engine accepts.
///
/// Must stay identical to the Rust `set_scene_resolution` match arms. Display resolution is the
/// default and comes first: it draws the canvas at the size it covers on the display, as Wallpaper
/// Engine does. Canvas size draws at the size the author made it, which costs the least.
enum SceneResolutionMode: String, CaseIterable, Sendable {
  case display
  case canvas

  @MainActor var title: String {
    switch self {
    case .display: L("Display resolution")
    case .canvas: L("Canvas size")
    }
  }
}

/// How a report line names the display and the wallpaper it is about: the display's own name, or
/// "Display 7" when it has none, then the wallpaper's title, its id or a generic word.
private enum ReportSubject {
  @MainActor static func display(name: String, id: UInt32) -> String {
    name.isEmpty ? L("Display \(String(id))") : name
  }

  @MainActor static func line(display: String, id: UInt32, wallpaper: String) -> String {
    "\(Self.display(name: display, id: id)) — \(wallpaper)"
  }
}

// MARK: - Video backends

/// What one running video wallpaper plays through, from the Video playback "In use now" list.
struct VideoBackendReport: Equatable, Identifiable, Sendable {
  var displayID: UInt32
  var displayName: String
  var wallpaperID: String
  var wallpaperTitle: String
  /// The bridge's own word, not translated.
  var backend: String
  var fallbackReason: String?

  var id: UInt32 { displayID }

  init(_ report: BridgeVideoBackendReport) {
    displayID = report.displayId
    displayName = report.displayName
    wallpaperID = report.wallpaperId
    wallpaperTitle = report.wallpaperTitle
    backend = report.backend
    fallbackReason = report.fallbackReason
  }

  /// "Studio Display — Beach: native (fallback: …)". The renderer's reason is shown only when it gave one.
  @MainActor var line: String {
    let text = ReportSubject.line(
      display: displayName, id: displayID,
      wallpaper: wallpaperTitle.isEmpty ? wallpaperID : wallpaperTitle)
    var line = "\(text): \(backend)"
    if let fallbackReason, !fallbackReason.isEmpty {
      line += " " + L("(fallback: \(fallbackReason))")
    }
    return line
  }
}

// MARK: - Scene wallpapers

/// The renderer that draws a scene, as the engine read it back. Native Metal is the only one.
enum SceneBackend: Equatable, Sendable {
  /// No backend reported yet: the scene is still being read, or it is held and nothing draws it.
  case preparing
  case nativeMetal
  /// A name this build does not know. It still drew the scene, so it is named verbatim, not folded
  /// into preparing.
  case other(String)

  init(name: String) {
    switch name {
    case "", "unknown": self = .preparing
    case "native_metal": self = .nativeMetal
    default: self = .other(name)
    }
  }

  @MainActor var title: String? {
    switch self {
    case .preparing: nil
    case .nativeMetal: L("Native Metal")
    case .other(let name): name
    }
  }
}

/// Why a scene is held and not drawn, by the bridge's names. A
/// category worded here in the user's language; the renderer's own explanation is shown beside it.
enum SceneFailureStage: Equatable, Sendable {
  case unsupported, prepare, compile, frame, surface
  /// A stage this build does not know. The scene is still not drawn, so it is named as given.
  case other(String)

  init(name: String) {
    switch name {
    case "unsupported": self = .unsupported
    case "prepare": self = .prepare
    case "compile": self = .compile
    case "frame": self = .frame
    case "surface": self = .surface
    default: self = .other(name)
    }
  }

  @MainActor var title: String {
    switch self {
    case .unsupported: L("it uses something Native Metal can't draw")
    case .prepare: L("Native Metal couldn't start")
    case .compile: L("its shaders didn't compile for Metal")
    case .frame: L("a frame failed in Native Metal")
    case .surface: L("Native Metal couldn't take the new display")
    case .other(let name): L("it stopped (\(name))")
    }
  }

  /// "not drawn — it uses something Native Metal can't draw (reason: …). Showing its last picture."
  ///
  /// The renderer's reason is English diagnostics and is shown only when it gave one. The closing sentence
  /// is the policy itself: nothing else draws the scene, and the surface keeps what it was showing.
  @MainActor func sentence(reason: String?) -> String {
    var text = L("not drawn — \(title)")
    if let reason, !reason.isEmpty { text += " " + L("(reason: \(reason))") }
    return text + ". " + L("Showing its last picture.")
  }
}

/// A scene held because Native Metal could not draw it: why, in the bridge's category and the renderer's own words.
struct SceneFailureReport: Equatable, Sendable {
  var stage: SceneFailureStage
  var reason: String?
}

/// How a scene's video textures reached the shaders sampling them. A scene with no video reports
/// `none`, which says nothing: naming it would read as a failure.
enum SceneVideoPath: String, Sendable {
  case bgra
  case nv12Direct = "nv12_direct"
  case nv12Converted = "nv12_converted"
  case nv12Mixed = "nv12_mixed"
  case nv12ConvertedPreparing = "nv12_converted_preparing"
  case yuv10Converted = "yuv10_converted"

  @MainActor var title: String {
    switch self {
    case .bgra: L("sampled directly, no conversion")
    case .nv12Direct: L("planes sampled directly, no conversion")
    case .nv12Converted: L("converted once per frame")
    case .nv12Mixed: L("planes sampled directly, plus one shared conversion")
    case .nv12ConvertedPreparing: L("converted once per frame, direct sampling still being prepared")
    case .yuv10Converted: L("10-bit, converted once per frame (HDR tone mapped to SDR)")
    }
  }
}

/// What a scene's update loop is doing. `unknown` is a running scene that could not be read, which
/// is not the same as one that is ticking; `stoppedAfterFailure` is one whose renderer gave up
/// after an error, which nobody paused, so it is never worded like a pause.
enum SceneUpdateMode: Equatable, Sendable {
  case continuous, waitingForEvent, waitingForDeadline, userPaused, policySuspended
  case stoppedAfterFailure, notApplicable, unknown
  /// A mode this build does not know, reported as given.
  case other(String)

  init(name: String) {
    switch name {
    case "continuous": self = .continuous
    case "waiting_for_event": self = .waitingForEvent
    case "waiting_for_deadline": self = .waitingForDeadline
    case "user_paused": self = .userPaused
    case "policy_suspended": self = .policySuspended
    case "stopped_after_failure": self = .stoppedAfterFailure
    case "not_applicable": self = .notApplicable
    case "unknown": self = .unknown
    default: self = .other(name)
    }
  }

  @MainActor var title: String {
    switch self {
    case .continuous: L("updating continuously")
    case .waitingForEvent: L("waiting for events")
    case .waitingForDeadline: L("waiting for a timer")
    case .userPaused: L("paused by you")
    case .policySuspended: L("suspended by the app")
    case .stoppedAfterFailure: L("stopped after a rendering failure")
    case .notApplicable: L("not applicable to this wallpaper")
    case .unknown: L("running — state could not be read")
    case .other(let name): L("state reported as \(name)")
    }
  }
}

/// The renderer's own words for why a scene keeps updating. `unknownInput` is deliberately not
/// folded into a generic phrase: it means the renderer found an input it could not account for and
/// kept the scene running, which is the whole diagnosis when on-demand seems to do nothing.
enum SceneDemandReason: Equatable, Sendable {
  case script, animation, particles, video, audioResponse, timeUniform, animatedSprite
  case dynamicMesh, puppet, feedback, textBinding, sound, nodeBinding, unknownInput
  case textLayoutPending
  /// Not a reason a clock runs: the scene has not finished a first frame, so it is starting.
  case noFrameYet
  /// A reason this build does not know, printed as given.
  case other(String)

  init(name: String) {
    switch name {
    case "script": self = .script
    case "animation": self = .animation
    case "particles": self = .particles
    case "video": self = .video
    case "audio_response": self = .audioResponse
    case "time_uniform": self = .timeUniform
    case "animated_sprite": self = .animatedSprite
    case "dynamic_mesh": self = .dynamicMesh
    case "puppet": self = .puppet
    case "feedback": self = .feedback
    case "text_binding": self = .textBinding
    case "sound": self = .sound
    case "node_binding": self = .nodeBinding
    case "unknown_input": self = .unknownInput
    case "text_layout_pending": self = .textLayoutPending
    case "no_frame_yet": self = .noFrameYet
    default: self = .other(name)
    }
  }

  @MainActor var title: String {
    switch self {
    case .script: L("a script")
    case .animation: L("animation")
    case .particles: L("particles")
    case .video: L("video")
    case .audioResponse: L("audio response")
    case .timeUniform: L("a time-based effect")
    case .animatedSprite: L("an animated sprite")
    case .dynamicMesh: L("a dynamic mesh")
    case .puppet: L("a puppet")
    case .feedback: L("a feedback pass")
    case .textBinding: L("bound text")
    case .sound: L("sound")
    case .nodeBinding: L("a bound node")
    case .unknownInput: L("an input the renderer could not account for")
    case .textLayoutPending: L("text still being laid out")
    case .noFrameYet: L("starting — no frame drawn yet")
    case .other(let name): name
    }
  }
}

/// One row of "Updating now": a running scene and what its update loop is doing.
struct SceneUpdateReport: Equatable, Identifiable, Sendable {
  /// The physical display id the engine reports, which `PanelController.retryScene(onPhysicalDisplay:)` takes.
  var displayID: UInt32
  var display: String
  var wallpaperID: String
  var wallpaperTitle: String
  var mode: SceneUpdateMode
  var reasons: [SceneDemandReason]

  var id: UInt32 { displayID }

  init(_ report: BridgeSceneUpdateModeReport) {
    displayID = report.displayId
    display = report.displayName
    wallpaperID = report.wallpaperId
    wallpaperTitle = report.wallpaperTitle
    mode = SceneUpdateMode(name: report.mode)
    reasons = report.reasons.map(SceneDemandReason.init(name:))
  }

  /// Retry is offered only for a scene that stopped after a failure. A pause or a suspension is not a
  /// fault to retry, and a scene that is starting is just slow.
  var canRetry: Bool { mode == .stoppedAfterFailure }

  /// "Display 7 — Beach: waiting for events", or the starting and stopped readings.
  ///
  /// A scene that stopped after a failure is checked first: one whose first frame failed also has no
  /// frame yet, and reading "starting" for ever is the lie this mode exists to end. The reasons
  /// describe what keeps a clock running, which is moot once it stopped.
  @MainActor var line: String {
    let subject = ReportSubject.line(
      display: display, id: displayID,
      wallpaper: wallpaperTitle.isEmpty
        ? (wallpaperID.isEmpty ? L("wallpaper") : wallpaperID) : wallpaperTitle)
    if mode == .stoppedAfterFailure { return "\(subject): \(mode.title)" }
    if reasons.contains(.noFrameYet) { return "\(subject): \(SceneDemandReason.noFrameYet.title)" }
    let named = reasons.map(\.title)
    return "\(subject): \(mode.title)\(named.isEmpty ? "" : " (\(named.joined(separator: ", ")))")"
  }
}

/// One row of "Drawn by": a running scene and the renderer that actually drew it.
struct SceneRendererReport: Equatable, Identifiable, Sendable {
  var displayID: UInt32
  var display: String
  var wallpaperID: String
  var wallpaperTitle: String
  var backend: SceneBackend
  /// Set when Native Metal could not draw the scene: the scene is held, not running on any backend.
  var failureStage: SceneFailureStage?
  var failureReason: String?
  var videoPath: SceneVideoPath?
  /// Whether the scene optimisation setting has reached this scene: true, false (not yet, on its
  /// next frame) or nil (the renderer could not answer, which is not "applied").
  var optimizationApplied: Bool?

  var id: UInt32 { displayID }

  init(_ report: BridgeSceneBackendReport) {
    displayID = report.displayId
    display = report.displayName
    wallpaperID = report.wallpaperId
    wallpaperTitle = report.wallpaperTitle
    backend = SceneBackend(name: report.backend)
    failureStage = report.failureStage.map(SceneFailureStage.init(name:))
    failureReason = report.failureReason
    videoPath = SceneVideoPath(rawValue: report.videoPath)
    optimizationApplied = report.optimizationApplied
  }

  /// "Display 7 — Beach: Native Metal — video: converted once per frame".
  ///
  /// Facts only. No backend yet means the scene is still being read; a held scene says why it is not
  /// drawn, in the renderer's own words; and the video path is named only when the renderer observed one.
  @MainActor var line: String {
    let subject = ReportSubject.line(
      display: display, id: displayID,
      wallpaper: wallpaperTitle.isEmpty
        ? (wallpaperID.isEmpty ? L("wallpaper") : wallpaperID) : wallpaperTitle)
    // First: a held scene has no backend, and "preparing" for ever is the lie this report exists to end.
    if let failureStage { return "\(subject): \(failureStage.sentence(reason: failureReason))" }
    guard let backendTitle = backend.title else {
      return "\(subject): \(L("preparing — no backend chosen yet"))"
    }
    var line = "\(subject): \(backendTitle)"
    if let videoPath { line += " " + L("— video: \(videoPath.title)") }
    return line
  }
}

/// The "In force now" line under Scene render optimisation: the saved choice set against what the
/// running scenes confirmed. The saved preference is never reported as proof that the setting took.
struct SceneOptimizationStatus: Equatable, Sendable {
  /// Whether the saved setting is on.
  var saved: Bool
  /// The scenes that have a backend, which are the ones that can answer.
  var total: Int
  var applied: Int
  /// Not yet reached; they pick it up on their next frame.
  var pending: Int

  init(reports: [SceneRendererReport], saved: Bool) {
    let answering = reports.filter { $0.backend != .preparing }
    self.saved = saved
    total = answering.count
    applied = answering.filter { $0.optimizationApplied == true }.count
    pending = answering.filter { $0.optimizationApplied == false }.count
  }

  /// A scene the renderer could not answer for counts as unknown, never as applied.
  var unknown: Int { total - applied - pending }

  /// Nil while no scene has a backend, when the row has nothing to say.
  @MainActor var text: String? {
    guard total > 0 else { return nil }
    let savedState = saved ? L("Saved on") : L("Saved off")
    if pending > 0 {
      return L("\(savedState); applying to \(pending) of \(total) running scenes on their next frame.")
    }
    if unknown > 0 {
      return L("\(savedState); \(applied) of \(total) running scenes confirmed, the rest could not be read.")
    }
    return applied == 1
      ? L("\(savedState) and in force on the running scene.")
      : L("\(savedState) and in force on all \(applied) running scenes.")
  }
}
