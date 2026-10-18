import SwiftUI

/// Page four: a few preferences. Launch at login, On battery, Keep windows in place and Send
/// performance data are drafts that **Continue** commits; Animate lock screen applies at once, like
/// Settings, and says so.
struct WelcomePreferencesPage: View {
  @Environment(FirstRunModel.self) private var model
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.welcomeIsCompact) private var compact

  var body: some View {
    let shown = model.shownPreferences
    let isCommitting = model.pending.contains(.preferences)
    let login = controller.generalSettings.launchAtLogin
    let lock = controller.lockScreenState
    let lockRow = model.lockScreenRow
    WelcomeColumn(spacing: compact ? 18 : 22) {
      WelcomePageHeader(
        title: Text("A few preferences"), lead: Text("You can change these later in Settings."))
      DividedRows(separatorInset: 54) {
        launchAtLoginRow(shown: shown, login: login, locked: isCommitting)
        batteryRow(shown: shown, locked: isCommitting)
        keepWindowsRow(shown: shown, locked: isCommitting)
        performanceDataRow(shown: shown)
        lockScreenRow(lock: lock, row: lockRow)
      }
      .welcomeSurface()
      if let failure = lock.error { WelcomeNotice(style: .error, message: failure) }
      if let error = model.error { WelcomeNotice(style: .error, message: error) }
    }
  }

  // MARK: Rows

  private func launchAtLoginRow(
    shown: WelcomePreferenceValues, login: LaunchAtLoginState, locked: Bool
  ) -> some View {
    WelcomePreferenceRow(symbol: "power", color: .green, title: Text("Launch at login")) {
      WelcomeColumn(spacing: 3) {
        note(Text("Wallpapers come back on their own after a restart."))
        // Switched off in System Settings, the login item stays off until the person allows it there.
        if let extra = login.note {
          Text(verbatim: extra)
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.warning.color)
        }
      }
    } control: {
      Toggle(
        isOn: Binding(
          get: { shown.launchAtLogin },
          set: { model.preferences.set(.launchAtLogin($0)) })
      ) { Text("Launch at login") }
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!model.canChangeLaunchAtLogin)
    }
  }

  private func batteryRow(shown: WelcomePreferenceValues, locked: Bool) -> some View {
    WelcomePreferenceRow(
      symbol: "battery.100.bolt", color: .green, title: Text("On battery")
    ) {
      note(Text("Keep wallpapers running, lower their quality, or pause them while on battery."))
    } control: {
      Picker(
        selection: Binding(
          get: { shown.batteryMode },
          set: { model.preferences.set(.batteryMode($0)) })
      ) {
        Text("Keep running").tag(BridgeBatteryMode.keepRunning)
        Text("Reduced quality").tag(BridgeBatteryMode.reducedQuality)
        Text("Pause").tag(BridgeBatteryMode.pause)
      } label: {
        Text("On battery")
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
      .disabled(locked)
    }
  }

  private func keepWindowsRow(shown: WelcomePreferenceValues, locked: Bool) -> some View {
    WelcomePreferenceRow(
      symbol: "cursorarrow.click", color: .blue,
      title: Text("Keep windows in place when clicking the wallpaper")
    ) {
      note(
        Text(
          "Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers."
        ))
    } control: {
      Toggle(
        isOn: Binding(
          get: { shown.keepsWindowsOnWallpaperClick },
          set: { model.preferences.set(.keepsWindows($0)) })
      ) { Text("Keep windows in place when clicking the wallpaper") }
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(locked)
    }
  }

  private func performanceDataRow(shown: WelcomePreferenceValues) -> some View {
    WelcomePreferenceRow(
      symbol: "waveform.path.ecg", color: .teal, title: Text("Send performance data")
    ) {
      note(
        Text(
          "Sends load times, frame rate, energy use and your Mac’s model once a day, to find what makes wallpapers slow. No names, files or account details."
        ))
    } control: {
      Toggle(
        isOn: Binding(
          get: { shown.sendsPerformanceData },
          set: { model.preferences.set(.performanceData($0)) })
      ) { Text("Send performance data") }
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!model.canChangePerformanceData)
    }
  }

  private func lockScreenRow(lock: LockScreenState, row: LockScreenRow) -> some View {
    WelcomePreferenceRow(symbol: "lock", color: .indigo, title: Text("Animate lock screen")) {
      switch row.note {
      case .unavailable(let reason): note(Text(verbatim: reason))
      case .working(let status): note(Text(verbatim: status))
      case .promise: note(Text("Experimental. Applies right away."))
      }
    } control: {
      Toggle(
        isOn: Binding(
          get: { lock.isRequested },
          set: { enabled in Task { await model.setLockScreen(enabled) } })
      ) { Text("Animate lock screen") }
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!row.isSwitchEnabled)
    }
  }

  private func note(_ text: Text) -> some View {
    text.font(.system(size: 12)).foregroundStyle(theme.surface.muted.color).textSelection(.enabled)
  }
}

/// One decision: a coloured glyph, its name and explanation, and the control at the trailing edge.
private struct WelcomePreferenceRow<Notes: View, Control: View>: View {
  let symbol: String
  let color: Color
  let title: Text
  @ViewBuilder var notes: Notes
  @ViewBuilder var control: Control

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 12) {
      SymbolTile(systemImage: symbol, color: color, size: .medium)
      WelcomeColumn(spacing: 3) {
        title
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
        notes
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 14)
  }
}
