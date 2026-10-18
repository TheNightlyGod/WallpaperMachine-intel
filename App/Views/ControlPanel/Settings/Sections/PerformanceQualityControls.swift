import SwiftUI

/// The Low, Medium, High and Custom segments. Custom is the state when the saved frame-rate limit
/// and render scale match no preset, so it is shown as the selection and can never be chosen.
///
/// A preset is never drafted: it shows as chosen only when the saved values say so, since a preset
/// changes two things in two engine calls and the first can succeed without the second.
struct PerformanceQualityPresetControl: View {
  /// Fills the width it is offered (a Quick Settings module) or is as wide as its labels (the
  /// trailing edge of the Preset row): see `SettingsSegmentedControl.fillsWidth`.
  var fillsWidth = true

  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    let active = controller.performanceSettings.activePreset
    let custom = "custom"
    SettingsSegmentedControl(
      segments: QualityPreset.allCases.map {
        .init(value: $0.rawValue, title: $0.title)
      } + [.init(value: custom, title: QualityPreset.customTitle, isEnabled: false)],
      selection: active?.rawValue ?? custom, isEnabled: !settings.isLocked("qualityPreset"),
      fillsWidth: fillsWidth
    ) { value in
      guard let preset = QualityPreset(rawValue: value) else { return }
      settings.perform("qualityPreset") { try await controller.applyQualityPreset(preset) }
    }
  }
}

/// The Frame rate limit slider: every rate from 10 to the highest display refresh, and one step past
/// it for no limit. It sends when it is let go.
struct PerformanceFrameRateControl: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let performance = controller.performanceSettings
    let slider = performance.slider
    SettingsSliderControl(
      key: "frameRateCap", saved: performance.sliderPosition, range: slider.range,
      readout: { slider.readout(atPosition: $0) }
    ) { position in
      try await controller.setFrameRateCap(slider.cap(atPosition: position).map(Int.init))
    }
  }
}
