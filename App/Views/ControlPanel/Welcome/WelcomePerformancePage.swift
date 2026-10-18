import SwiftUI

/// Page three: how smoothly wallpapers run against how much energy they use. A preset or the slider
/// is only a draft; **Continue** sends it.
struct WelcomePerformancePage: View {
  @Environment(FirstRunModel.self) private var model
  @Environment(\.panelTheme) private var theme
  @Environment(\.welcomeIsCompact) private var compact

  private let presets = QualityPreset.allCases

  var body: some View {
    WelcomeColumn(spacing: compact ? 18 : 24) {
      WelcomePageHeader(
        title: Text("Performance"),
        lead: Text(
          "Choose how smoothly wallpapers run and how much energy they use. You can change this later in Settings › Performance."
        ))
      presetGroup
      limitGroup
      if let error = model.error { WelcomeNotice(style: .error, message: error) }
    }
  }

  // MARK: Presets

  private var isLocked: Bool { model.pending.contains(.performance) }

  private var presetGroup: some View {
    let active = model.shownPreset
    return WelcomeColumn(spacing: 10) {
      WelcomeGroupLabel(systemImage: "slider.vertical.3", title: Text("Quality preset"))
      WelcomeChoiceGroup(
        label: L("Quality preset"), count: presets.count,
        selectedIndex: active.flatMap { presets.firstIndex(of: $0) }, isEnabled: !isLocked,
        select: { model.choosePreset(presets[$0]) }
      ) {
        WelcomeTileRow(spacing: 10) {
          ForEach(presets, id: \.self) { preset in
            WelcomeTile(
              isSelected: active == preset, isEnabled: !isLocked,
              action: { model.choosePreset(preset) }
            ) {
              WelcomeColumn(spacing: 4) {
                title(of: preset).font(.system(size: 13, weight: .semibold))
                note(of: preset)
                  .font(.system(size: 12))
                  .foregroundStyle(theme.surface.muted.color)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.trailing, 14)
              .frame(maxWidth: .infinity, alignment: .topLeading)
            }
          }
        }
      }
      if active == nil {
        WelcomeNote(
          text: Text("Custom: the frame-rate limit and render scale match none of the presets."))
      }
    }
  }

  @ViewBuilder private func title(of preset: QualityPreset) -> some View {
    switch preset {
    case .low: Text("Low")
    case .medium: Text("Medium")
    case .high: Text("High")
    }
  }

  @ViewBuilder private func note(of preset: QualityPreset) -> some View {
    switch preset {
    case .low: Text("Up to 30 fps at half resolution. Uses the least energy.")
    case .medium: Text("Up to 60 fps at 75% resolution.")
    case .high: Text("No frame-rate limit, full resolution. The default.")
    }
  }

  // MARK: Frame rate limit

  private var limitGroup: some View {
    let slider = model.frameRateSlider
    let position = model.frameRatePosition
    let readout = slider.readout(atPosition: position)
    return WelcomeColumn(spacing: 10) {
      WelcomeGroupLabel(systemImage: "display", title: Text("Frame rate limit"))
      HStack(spacing: 14) {
        // No `step:`: on macOS it draws a tick for every one of the fifty-odd positions. The
        // binding rounds to a whole position instead, and the readout says where it is.
        Slider(
          value: Binding(
            get: { Double(model.frameRatePosition) },
            set: { model.setFrameRatePosition(Int($0.rounded())) }),
          in: Double(slider.range.lowerBound)...Double(slider.range.upperBound)
        ) {
          Text("Frame rate limit")
        }
        .labelsHidden()
        .disabled(isLocked)
        .accessibilityValue(readout)
        // Without a step VoiceOver would move by a fraction of the range; one position per swipe
        // keeps every limit reachable.
        .accessibilityAdjustableAction { direction in
          let range = slider.range
          let current = model.frameRatePosition
          switch direction {
          case .increment: model.setFrameRatePosition(min(current + 1, range.upperBound))
          case .decrement: model.setFrameRatePosition(max(current - 1, range.lowerBound))
          @unknown default: break
          }
        }
        Text(verbatim: readout)
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .frame(minWidth: 76, alignment: .trailing)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 13)
      .welcomeSurface()
      WelcomeNote(
        text: Text(
          "At the top of the slider there is no limit, and each display runs at up to 60 fps unless you choose more for it. A lower limit saves energy."
        ))
    }
  }
}
