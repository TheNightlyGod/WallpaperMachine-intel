import SwiftUI

/// Settings › Keyboard shortcuts: the six shortcuts that work in any app, recorded by pressing the
/// keys, and what the Shortcuts app and links can do.
struct ShortcutsSettingsSection: View {
  // The card has no title of its own: the page's header already says "Keyboard shortcuts". The
  // words stay searchable as a keyword of every row, which a group title used to give them.
  private static let hotkeys = SettingsItem.Group("hotkeys")
  private static let automation = SettingsItem.Group("automation")

  private static let recordWords: [LocalizedStringResource] = [
    "Keyboard shortcuts", "Not set", "Record…", "Change…", "Clear", "Press the new shortcut…",
  ]

  static let togglePlayback = SettingsItem(
    id: "shortcuts.toggle-playback", section: .shortcuts, group: hotkeys,
    title: "Play or pause wallpapers", keywords: recordWords)
  static let toggleMute = SettingsItem(
    id: "shortcuts.toggle-mute", section: .shortcuts, group: hotkeys,
    title: "Mute or unmute wallpapers", keywords: recordWords)
  static let previousWallpaper = SettingsItem(
    id: "shortcuts.previous-wallpaper", section: .shortcuts, group: hotkeys,
    title: "Previous wallpaper", keywords: recordWords)
  static let nextWallpaper = SettingsItem(
    id: "shortcuts.next-wallpaper", section: .shortcuts, group: hotkeys, title: "Next wallpaper",
    keywords: recordWords)
  static let randomWallpaper = SettingsItem(
    id: "shortcuts.random-wallpaper", section: .shortcuts, group: hotkeys,
    title: "Random wallpaper", keywords: recordWords)
  static let openControlPanel = SettingsItem(
    id: "shortcuts.open-control-panel", section: .shortcuts, group: hotkeys,
    title: "Open the control panel", keywords: recordWords)
  static let footnote = SettingsItem(
    id: "shortcuts.footnote", section: .shortcuts, group: hotkeys, title: "Keyboard shortcuts",
    note:
      "They work whichever app is in front. Hold ⌘, ⌥ or ⌃ with the key; F13 to F20 work alone. No permission is needed."
  )
  static let links = SettingsItem(
    id: "shortcuts.links", section: .shortcuts, group: automation, title: "Shortcuts app and links")

  static let items = [
    togglePlayback, toggleMute, previousWallpaper, nextWallpaper, randomWallpaper, openControlPanel,
    footnote, links,
  ]

  /// The item of a shortcut's row.
  static func item(for action: HotKeyAction) -> SettingsItem {
    switch action {
    case .togglePlayback: togglePlayback
    case .toggleMute: toggleMute
    case .previousWallpaper: previousWallpaper
    case .nextWallpaper: nextWallpaper
    case .randomWallpaper: randomWallpaper
    case .openControlPanel: openControlPanel
    }
  }

  @Environment(PanelController.self) private var controller
  @State private var recorder = ShortcutsRecorderModel()
  @FocusState private var focus: HotKeyAction?

  var body: some View {
    SettingsPage(.shortcuts) {
      SettingsGroup(Self.hotkeys, in: .shortcuts) {
        ForEach(controller.hotKeyRows) { row in
          ShortcutsRow(row: row, recorder: recorder, focus: $focus)
        }
        DisplaysItemNote(item: Self.footnote)
      }
      SettingsGroup(Self.automation, in: .shortcuts) {
        SettingsDisclosure(Self.links) { ShortcutsLinksContent() }
      }
    }
    // Row buttons share one size across Settings.
    .controlSize(.small)
    // The prompt is a status the page reads out as the row starts recording.
    .announcesChanges(of: recorder.recording == nil ? nil : L("Press the new shortcut…"))
    .onAppear { recorder.controller = controller }
    // A recording belongs to the page: leaving it, or the window losing focus, ends it.
    .onDisappear { recorder.end() }
    .onChange(of: recorder.focus) { _, action in
      guard let action else { return }
      focus = action
      recorder.consumeFocus()
    }
  }
}

/// One shortcut: what it does, the keys recorded for it or "Not set", and Record…/Change… and
/// Clear. While it records it asks for the keys and offers Cancel. The keys, the main button and
/// Clear each keep a slot of one width, so the buttons of the six rows line up in columns.
private struct ShortcutsRow: View {
  let row: HotKeyRow
  let recorder: ShortcutsRecorderModel
  var focus: FocusState<HotKeyAction?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// The widths of the slots: the keys, and each button's title.
  private static let keysWidth: CGFloat = 76
  private static let buttonTitleWidth: CGFloat = 52

  var body: some View {
    let isRecording = recorder.recording == row.action
    DisplaysRow(
      item: ShortcutsSettingsSection.item(for: row.action), title: row.title, note: "",
      alert: row.error, labelsControl: false
    ) {
      HStack(spacing: 8) {
        if isRecording {
          Text("Press the new shortcut…")
            .font(.system(size: 12))
            .foregroundStyle(theme.accent.accent.color)
            .frame(minWidth: Self.keysWidth, alignment: .trailing)
          Button { recorder.cancel() } label: { slotTitle("Cancel") }
            .focused(focus, equals: row.action)
          clearSlot
        } else {
          keys.frame(minWidth: Self.keysWidth, alignment: .trailing)
          Button { recorder.begin(row.action) } label: {
            slotTitle(row.shortcut == nil ? "Record…" : "Change…")
          }
          .focused(focus, equals: row.action)
          .disabled(controller.isBusy(PanelActionCoordinator.key("hotkeySet", id: row.action.rawValue)))
          if row.shortcut != nil {
            Button {
              controller.launch(PanelActionCoordinator.key("hotkeyClear", id: row.action.rawValue)) {
                try await controller.clearHotKey(row.action)
              }
            } label: {
              slotTitle("Clear")
            }
          } else {
            clearSlot
          }
        }
      }
    }
    .announcesChanges(of: row.error)
    .accessibilityIdentifier("hotkey-\(row.action.rawValue)")
  }

  /// A button title in a slot at least as wide as the column, so Record… and Change… line up.
  private func slotTitle(_ title: LocalizedStringKey) -> some View {
    Text(title).frame(minWidth: Self.buttonTitleWidth)
  }

  /// The room Clear takes in a row that has no shortcut to clear, so the main buttons keep their
  /// column. Not drawn and not read out.
  private var clearSlot: some View {
    Button {} label: { slotTitle("Clear") }
      .hidden()
      .accessibilityHidden(true)
  }

  /// The recorded keys in a small keycap, or "Not set".
  @ViewBuilder
  private var keys: some View {
    if let shortcut = row.shortcut {
      Text(verbatim: shortcut)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(theme.surface.well.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
        }
        .accessibilityLabel(Text(verbatim: shortcut))
    } else {
      Text("Not set")
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
    }
  }
}

/// The Shortcuts app and links disclosure: what the actions do and the links that run them.
private struct ShortcutsLinksContent: View {
  @Environment(\.panelTheme) private var theme

  /// The links, written out; an id stands for the id of a wallpaper, saved playlist, preset or layout.
  private static let links = [
    "wallpapermachine://toggle", "wallpapermachine://play", "wallpapermachine://pause",
    "wallpapermachine://mute", "wallpapermachine://unmute", "wallpapermachine://togglemute",
    "wallpapermachine://next", "wallpapermachine://previous", "wallpapermachine://random",
    "wallpapermachine://random?from=favorites", "wallpapermachine://apply?id=…",
    "wallpapermachine://apply?id=…&display=all", "wallpapermachine://playlist?id=…",
    "wallpapermachine://preset?id=…", "wallpapermachine://layout?id=…",
    "wallpapermachine://open?page=settings",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "The Shortcuts app can control playback, mute or unmute wallpapers, go to the previous or next wallpaper, apply a wallpaper, saved playlist or property preset, and open this window. Siri and Spotlight can run these actions too."
      )
      Text(
        "Apply Display Layout restores a saved arrangement across its displays. Choose the layout by name in Shortcuts, or use its saved id in a layout link."
      )
      Text(
        "Random Wallpaper changes a display to a wallpaper other than the one it shows, and goes through all of them before it repeats one. It can draw from your favorites only: choose Favorites in Shortcuts, or use from=favorites in a link."
      )
      Text(
        "Links can run the same actions. Wallpaper and playlist actions accept display= for a specific screen; otherwise they use the target display. An apply link also accepts display=all, and Apply Wallpaper has an On all displays option, to use every display at once. Property presets affect their wallpaper on every display. Choose saved items by name in Shortcuts."
      )
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Self.links, id: \.self) { link in
          Text(verbatim: link)
            .font(.system(size: 11.5, design: .monospaced))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(theme.surface.well.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .font(.system(size: 12))
    .foregroundStyle(theme.surface.muted.color)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}
