import SwiftUI

/// The Energy use readout: what this app drew over the last few seconds, graded, with the change
/// compared with before the last quality setting moved.
///
/// It is its own view so that the reading, which arrives every two seconds while Settings is on
/// screen, redraws only this and not the page around it. It is not announced to VoiceOver as it
/// changes, which would speak every two seconds; the row is read once when focused.
struct PerformanceEnergyReadout: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    PerformanceEnergyReading(reading: controller.energyReadout)
  }
}

/// A reading drawn: the states of the readout, which depend on nothing but the reading.
struct PerformanceEnergyReading: View {
  let reading: EnergyReadout

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch reading.status {
      case .unavailable:
        Text("Unavailable on this Mac").foregroundStyle(theme.surface.muted.color)
      case .measuring:
        Text("Measuring…").foregroundStyle(theme.surface.muted.color)
        comparison(reading)
      case .ready:
        if let first = reading.caveats.first {
          Text(verbatim: first.title).font(.system(size: 13, weight: .semibold))
          figures(reading)
          ForEach(reading.caveats, id: \.self) { caveat in
            Text(verbatim: caveat.note)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
        } else {
          total(reading)
          figures(reading)
          if let share = reading.batteryShareNote {
            Text(verbatim: share)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        comparison(reading)
      }
    }
    .font(.system(size: 13))
    .frame(maxWidth: .infinity, alignment: .leading)
    // The row names it; what it reads is its value, said once when VoiceOver reaches it and never
    // announced as the figures change.
    .accessibilityElement(children: .ignore)
    .accessibilityValue(Text(verbatim: summary))
  }

  /// The readout as one spoken line: the grade or the state, the figures and the notes.
  var summary: String {
    switch reading.status {
    case .unavailable: return L("Unavailable on this Mac")
    case .measuring: return ([L("Measuring…")] + comparisonLine).joined(separator: ". ")
    case .ready:
      var parts: [String] = []
      if let first = reading.caveats.first {
        parts.append(first.title)
      } else {
        parts.append(EnergyReadout.milliwatts(reading.totalMilliwatts))
        if let title = reading.levelTitle { parts.append(title) }
      }
      parts.append("\(L("CPU")) \(EnergyReadout.milliwatts(reading.cpuMilliwatts))")
      parts.append("\(L("GPU")) \(EnergyReadout.milliwatts(reading.gpuMilliwatts))")
      parts += reading.caveats.isEmpty ? [reading.batteryShareNote].compactMap { $0 } : reading.caveats.map(\.note)
      return (parts + comparisonLine).joined(separator: ". ")
    }
  }

  private var comparisonLine: [String] { [reading.comparisonNote()].compactMap { $0 } }

  /// The total power in large type, with its grade in a pill.
  private func total(_ reading: EnergyReadout) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(verbatim: EnergyReadout.milliwatts(reading.totalMilliwatts))
        .font(.system(size: 30, weight: .bold).monospacedDigit())
        .minimumScaleFactor(0.7)
        .lineLimit(1)
      if let level = reading.level, let title = reading.levelTitle {
        let color = tint(for: level)
        HStack(spacing: 5) {
          Circle().fill(color).frame(width: 7, height: 7)
          Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(minHeight: 22)
        .background(color.opacity(0.14), in: Capsule())
      }
    }
  }

  /// CPU and GPU side by side.
  private func figures(_ reading: EnergyReadout) -> some View {
    HStack(alignment: .top, spacing: 32) {
      figure("CPU", reading.cpuMilliwatts)
      figure("GPU", reading.gpuMilliwatts)
    }
  }

  private func figure(_ title: LocalizedStringKey, _ milliwatts: Double) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.surface.muted.color)
      Text(verbatim: EnergyReadout.milliwatts(milliwatts))
        .font(.system(size: 17, weight: .semibold).monospacedDigit())
    }
  }

  /// What the last change did, set apart by a hairline.
  @ViewBuilder
  private func comparison(_ reading: EnergyReadout) -> some View {
    if let note = reading.comparisonNote() {
      Rectangle().fill(theme.surface.divider.color).frame(height: 0.5).padding(.top, 2)
      Text(verbatim: note)
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.text.color)
    }
  }

  private func tint(for level: EnergyLevel) -> Color {
    switch level {
    case .low: theme.surface.approved.color
    case .medium: theme.surface.warning.color
    case .high: theme.surface.danger.color
    }
  }
}
