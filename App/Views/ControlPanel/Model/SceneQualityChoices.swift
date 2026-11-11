import Foundation

/// The scene quality menus of Settings › Performance › Quality, with Wallpaper Engine's levels.
extension BridgeSceneQuality {
  /// Wallpaper Engine's first-run "medium" preset, the engine's default (`SceneQuality::default()`
  /// in `Renderer/Core/src/project/scene.rs`).
  static let wallpaperEngineDefault = BridgeSceneQuality(
    msaa: .off, shadows: .medium, volumetrics: .medium, reflections: true, postProcessing: .enabled)

  /// "msaa=2 shadows=medium …", the words diagnostics write. Not translated.
  var diagnosticText: String {
    "msaa=\(msaa.sampleCount) shadows=\(shadows.word) volumetrics=\(volumetrics.word) "
      + "reflection=\(reflections) post=\(postProcessing.word)"
  }
}

extension BridgeMsaa: CaseIterable {
  public static let allCases: [BridgeMsaa] = [.off, .x2, .x4, .x8]

  var sampleCount: Int {
    switch self {
    case .off: 0
    case .x2: 2
    case .x4: 4
    case .x8: 8
    }
  }

  @MainActor var title: String {
    switch self {
    case .off: L("Off")
    // "2×": a number and a sign, the same in every language.
    default: "\(sampleCount)×"
    }
  }
}

extension BridgeQualityLevel: CaseIterable {
  public static let allCases: [BridgeQualityLevel] = [.off, .low, .medium, .high, .ultra]

  var word: String {
    switch self {
    case .off: "disabled"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    case .ultra: "ultra"
    }
  }

  @MainActor var title: String {
    switch self {
    case .off: L("Off")
    case .low: L("Low")
    case .medium: L("Medium")
    case .high: L("High")
    case .ultra: L("Ultra")
    }
  }
}

extension BridgePostProcessing: CaseIterable {
  public static let allCases: [BridgePostProcessing] = [.disabled, .enabled, .ultra, .displayHdr]

  var word: String {
    switch self {
    case .disabled: "disabled"
    case .enabled: "enabled"
    case .ultra: "ultra"
    case .displayHdr: "displayhdr"
    }
  }

  @MainActor var title: String {
    switch self {
    case .disabled: L("Disabled")
    case .enabled: L("Enabled")
    case .ultra: L("Ultra")
    case .displayHdr: L("Display HDR")
    }
  }
}

/// One running scene's "Quality in force" line: what the renderer actually draws.
struct SceneQualityInForceReport: Equatable, Identifiable {
  var displayID: UInt32
  var display: String
  var wallpaperTitle: String
  var quality: BridgeSceneQuality?

  var id: UInt32 { displayID }

  @MainActor var line: String {
    let subject =
      (display.isEmpty ? L("Display \(String(displayID))") : display) + " — "
      + (wallpaperTitle.isEmpty ? L("wallpaper") : wallpaperTitle)
    guard let quality else { return "\(subject): \(L("preparing — no backend chosen yet"))" }
    let msaa =
      quality.msaa == .off ? L("Antialiasing off") : L("Antialiasing \(quality.msaa.sampleCount)×")
    let parts = [
      msaa, L("Shadows: \(quality.shadows.title)"), L("Volumetrics: \(quality.volumetrics.title)"),
      quality.reflections ? L("Reflections on") : L("Reflections off"),
      L("Post-processing: \(quality.postProcessing.title)"),
    ]
    return "\(subject): " + parts.joined(separator: ", ")
  }
}
