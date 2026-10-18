import SwiftUI

/// A display's Playlist disclosure: how it changes on its own, what a rotation draws from, how
/// often, the display's own list, the failures it skips, a day and a night wallpaper, and the saved
/// playlist it was copied from.
struct DisplaysPlaylistDisclosure: View {
  let display: DisplayRow
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    let forced = card.forced
    let state = controller.playlistState(for: display.id)
    let busy = controller.isStoreBusy
    let off = busy || !display.enabled
    // "Playlist" while it is off, "Playlist: Rotate wallpapers" otherwise.
    let title =
      state.playlist.mode == .off
      ? settings.text(DisplaysSettingsSection.playlist.title)
      : L("Playlist: \(Self.modeTitle(state.playlist.mode))")

    DisplaysDisclosure(
      item: DisplaysSettingsSection.playlist, display: display.id, title: title,
      summary: state.showsResume ? L("Playlist paused") : nil, card: card
    ) {
      DisplaysPlaylistModeRow(display: display, state: state, off: off, forced: forced)
      if state.showsResume {
        DisplaysRow(
          item: DisplaysSettingsSection.playlistHeld, forced: forced, identity: display.id,
          labelsControl: false
        ) {
          Button("Resume playlist") {
            controller.launch(PanelActionCoordinator.key("playlistResume", id: display.id)) {
              try await controller.resumePlaylist(display: display.id)
            }
          }
          .disabled(off)
        }
      }
      switch state.playlist.mode {
      case .rotate: DisplaysRotateRows(display: display, state: state, off: off, card: card)
      case .dayNight: DisplaysDayNightRows(display: display, state: state, off: off, forced: forced)
      case .off: EmptyView()
      }
      DisplaysPlanRow(display: display, state: state, off: off, forced: forced)
    }
  }

  /// "Off", "Rotate wallpapers" or "Day and night" in the panel's language.
  @MainActor static func modeTitle(_ mode: PlaylistMode) -> String {
    switch mode {
    case .off: L("Off")
    case .rotate: L("Rotate wallpapers")
    case .dayNight: L("Day and night")
    }
  }
}

// MARK: - Mode

private struct DisplaysPlaylistModeRow: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    DisplaysRow(
      item: DisplaysSettingsSection.playlistMode, forced: forced, identity: display.id,
      controlLabel: L("\(controller.settings.text(DisplaysSettingsSection.playlistMode.title)) for \(display.title)")
    ) {
      let mode = controller.displaysSettings.binding(
        PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "mode"),
        current: state.playlist.mode
      ) { mode in try await controller.editPlaylist(.mode(mode), display: display.id) }
      DisplaysTitleMenu(
        selection: mode, title: DisplaysPlaylistDisclosure.modeTitle(mode.wrappedValue), width: 180
      ) {
        Text("Off").tag(PlaylistMode.off)
        Text("Rotate wallpapers").tag(PlaylistMode.rotate)
        Text("Day and night").tag(PlaylistMode.dayNight)
      }
      .disabled(off)
    }
  }
}

// MARK: - Rotate

private struct DisplaysRotateRows: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let forced = card.forced
    let playlist = state.playlist
    let collections = controller.collectionRows
    let selection = model.intervalDraft(of: display.id).selection(for: playlist)
    let name = { (title: LocalizedStringResource) in
      L("\(controller.settings.text(title)) for \(display.title)")
    }

    // What the rotation draws from.
    DisplaysRow(
      item: DisplaysSettingsSection.playlistSource, note: sourceNote(collections), forced: forced,
      identity: display.id, controlLabel: name(DisplaysSettingsSection.playlistSource.title)
    ) {
      DisplaysTitleMenu(
        selection: model.binding(
          PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "source"),
          current: state.source
        ) { choice in
          // A collection that is gone is shown so the menu has something to say, and chooses nothing.
          guard let edit = choice.edit else { return }
          try await controller.editPlaylist(edit, display: display.id)
        },
        title: sourceTitle(state.source, collections: collections)
      ) {
        Text("All wallpapers").tag(PlaylistSourceChoice.all)
        Text("Favorites").tag(PlaylistSourceChoice.favorites)
        Text("This display’s list (\(state.listedCount))").tag(PlaylistSourceChoice.list)
        if !collections.isEmpty {
          Section("Collections") {
            ForEach(collections) {
              Text(verbatim: $0.name).tag(PlaylistSourceChoice.collection(id: $0.id))
            }
          }
        }
        if state.source == .missingCollection {
          Text("A collection that no longer exists").tag(PlaylistSourceChoice.missingCollection)
        }
      }
      .disabled(off)
    }

    DisplaysRow(
      item: DisplaysSettingsSection.playlistOrder, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistOrder.title)
    ) {
      let order = model.binding(
        PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "order"),
        current: playlist.order
      ) { order in try await controller.editPlaylist(.order(order), display: display.id) }
      DisplaysTitleMenu(
        selection: order, title: order.wrappedValue == .shuffle ? L("Shuffle") : L("In order"), width: 140
      ) {
        Text("In order").tag(PlaylistOrder.sequential)
        Text("Shuffle").tag(PlaylistOrder.shuffle)
      }
      .disabled(off)
    }

    DisplaysRow(
      item: DisplaysSettingsSection.playlistInterval, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistInterval.title)
    ) {
      let interval = model.binding(
        PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "interval"),
        current: selection
      ) { option in try await model.chooseInterval(option, display: display.id) }
      DisplaysTitleMenu(
        selection: interval,
        title: {
          switch interval.wrappedValue {
          case .preset(let minutes): IntervalChoice.title(minutes: minutes)
          case .unlock: L("Each time the Mac is unlocked")
          case .custom: L("Custom")
          }
        }(), width: 220
      ) {
        ForEach(IntervalChoice.presets, id: \.self) { minutes in
          Text(verbatim: IntervalChoice.title(minutes: minutes)).tag(DisplaysIntervalOption.preset(minutes))
        }
        Text("Each time the Mac is unlocked").tag(DisplaysIntervalOption.unlock)
        Text("Custom").tag(DisplaysIntervalOption.custom)
      }
      .disabled(off)
    }

    if selection == .custom {
      // A text Return refused stays in the field, and the note turns into the alert that says what
      // the field accepts.
      let refused = model.intervalDraft(of: display.id).isInvalid
      let accepted = L("Any whole number of minutes, up to \(IntervalChoice.range.upperBound).")
      DisplaysRow(
        item: DisplaysSettingsSection.playlistCustom, note: refused ? "" : nil,
        alert: refused ? accepted : nil, forced: forced, identity: display.id
      ) {
        DisplaysCustomIntervalField(display: display.id, saved: playlist.interval)
          .disabled(off)
      }
      .announcesChanges(of: refused ? accepted : nil)
    }

    if playlist.source == .list {
      DisplaysOrderEditor(display: display, state: state, off: off, card: card)
    }

    if !state.skipped.isEmpty {
      DisplaysSkippedDisclosure(display: display, state: state, off: off, card: card)
    }

    DisplaysRow(
      item: DisplaysSettingsSection.playlistNext, note: nextNote(state), forced: forced,
      identity: display.id, labelsControl: false
    ) {
      Button("Change now") {
        controller.launch(PanelActionCoordinator.key("playlistSkip", id: display.id)) {
          try await controller.skipPlaylist(display: display.id)
        }
      }
      .disabled(off)
    }
  }

  /// What the Wallpapers menu says for the source in use.
  private func sourceTitle(_ source: PlaylistSourceChoice, collections: [CollectionRow]) -> String {
    switch source {
    case .all: L("All wallpapers")
    case .favorites: L("Favorites")
    case .list: L("This display’s list (\(state.listedCount))")
    case .collection(let id): collections.first { $0.id == id }?.name ?? L("A collection that no longer exists")
    case .missingCollection: L("A collection that no longer exists")
    }
  }

  /// Why a source may read as it does: its collection is gone, or there are none to choose from.
  private func sourceNote(_ collections: [CollectionRow]) -> String {
    if state.source == .missingCollection {
      return L(
        "The collection this rotation used was deleted, so it plays nothing until you choose another source."
      )
    }
    return collections.isEmpty ? L("Collections you make in Installed appear here too.") : ""
  }

  private func nextNote(_ state: PlaylistState) -> String {
    if state.playlist.trigger == .unlock {
      return L("Changes when you unlock the Mac, while wallpapers are playing.")
    }
    if let time = state.nextChangeText(locale: PanelLocale.shared.locale) {
      return L("Around \(time), if wallpapers are playing then.")
    }
    return L("Starts counting once wallpapers play.")
  }
}

/// The minutes field of the Custom interval. It shows the saved minutes until something is typed and
/// commits on Return or when it is left. Return on a text that is not a whole number in range keeps
/// the text and the keyboard; leaving puts the saved minutes back.
private struct DisplaysCustomIntervalField: View {
  let display: String
  let saved: Int

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @FocusState private var isFocused: Bool

  var body: some View {
    let model = controller.displaysSettings
    HStack(spacing: 6) {
      TextField(
        noLabel,
        text: Binding(
          get: { model.intervalDraft(of: display).text ?? String(saved) },
          set: { model.setIntervalText($0, display: display) })
      )
      .textFieldStyle(.roundedBorder)
      .font(.system(size: 12.5).monospacedDigit())
      .multilineTextAlignment(.trailing)
      .frame(width: 64)
      .focused($isFocused)
      .onSubmit {
        controller.launch(PanelActionCoordinator.key("playlistSetting", id: display, detail: "interval")) {
          try await model.commitCustomInterval(display: display)
        }
      }
      .onChange(of: isFocused) { _, focused in
        guard !focused else { return }
        controller.launch(PanelActionCoordinator.key("playlistSetting", id: display, detail: "interval")) {
          try await model.leaveCustomInterval(display: display)
        }
      }
      .onChange(of: model.intervalFocus, initial: true) { _, target in
        guard target == display else { return }
        isFocused = true
        model.consumeIntervalFocus()
      }
      DisplaysUnitLabel(text: L("min"))
    }
  }
}

// MARK: - Temporarily skipped

private struct DisplaysSkippedDisclosure: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let titles = Dictionary(
      controller.store.librarySnapshot.wallpapers.filter { id in state.skipped.contains { $0.id == id.id } }
        .map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    DisplaysDisclosure(
      item: DisplaysSettingsSection.playlistSkipped, display: display.id,
      title: L("Temporarily skipped (\(state.skipped.count))"), card: card
    ) {
      DisplaysItemNote(item: DisplaysSettingsSection.playlistSkipped, forced: true)
      ForEach(state.skipped) { skipped in
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: titles[skipped.id] ?? skipped.id)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Text(verbatim: skipped.message)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      HStack {
        Button("Allow these wallpapers again") {
          controller.launch(PanelActionCoordinator.key("playlistClearFailures", id: display.id)) {
            try await controller.clearPlaylistFailures(display: display.id)
          }
        }
        .disabled(off)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }
}

// MARK: - Day and night

private struct DisplaysDayNightRows: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let playlist = state.playlist
    let choices = controller.automationTargets.wallpapers.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    let name = { (title: LocalizedStringResource) in
      L("\(controller.settings.text(title)) for \(display.title)")
    }

    DisplaysRow(
      item: DisplaysSettingsSection.playlistDay, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistDay.title)
    ) {
      wallpaperPicker(
        key: "dayWallpaper", current: playlist.dayWallpaperID ?? "", choices: choices
      ) { try await controller.editPlaylist(.dayWallpaper($0), display: display.id) }
    }
    DisplaysRow(
      item: DisplaysSettingsSection.playlistDayStart, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistDayStart.title)
    ) {
      DisplaysClockField(
        binding: model.binding(
          PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "dayStart"),
          current: playlist.dayStart
        ) { minutes in
          guard let start = ClockMinute(minutes: minutes) else { return }
          try await controller.editPlaylist(.dayStart(start), display: display.id)
        }
      )
      .disabled(off)
    }
    DisplaysRow(
      item: DisplaysSettingsSection.playlistNight, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistNight.title)
    ) {
      wallpaperPicker(
        key: "nightWallpaper", current: playlist.nightWallpaperID ?? "", choices: choices
      ) { try await controller.editPlaylist(.nightWallpaper($0), display: display.id) }
    }
    DisplaysRow(
      item: DisplaysSettingsSection.playlistNightStart, forced: forced, identity: display.id,
      controlLabel: name(DisplaysSettingsSection.playlistNightStart.title)
    ) {
      DisplaysClockField(
        binding: model.binding(
          PanelActionCoordinator.key("playlistSetting", id: display.id, detail: "nightStart"),
          current: playlist.nightStart
        ) { minutes in
          guard let start = ClockMinute(minutes: minutes) else { return }
          try await controller.editPlaylist(.nightStart(start), display: display.id)
        }
      )
      .disabled(off)
    }
    if let time = state.nextChangeText(locale: PanelLocale.shared.locale) {
      DisplaysRow(
        item: DisplaysSettingsSection.playlistSwitch, forced: forced, identity: display.id,
        labelsControl: false
      ) {
        Text(verbatim: L("Around \(time)."))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// A menu of the wallpapers that can play, with "Leave as it is" first.
  private func wallpaperPicker(
    key: String, current: String, choices: [AutomationTargets.Choice],
    commit: @escaping @MainActor (String?) async throws -> Void
  ) -> some View {
    DisplaysTitleMenu(
      selection: controller.displaysSettings.binding(
        PanelActionCoordinator.key("playlistSetting", id: display.id, detail: key), current: current
      ) { id in try await commit(id.isEmpty ? nil : id) },
      title: choices.first { $0.target.id == current }?.title ?? L("Leave as it is")
    ) {
      Text("Leave as it is").tag("")
      ForEach(choices) { Text(verbatim: $0.title).tag($0.target.id) }
    }
    .disabled(off)
  }
}

/// A time of day as a field with a stepper, set in minutes after midnight. The date it edits is
/// only a carrier for the hour and the minute: a fixed day, read and written in the calendar's own
/// components, so a change of the clock never moves the time.
struct DisplaysClockField: View {
  let binding: Binding<Int>

  var body: some View {
    DatePicker(
      noLabel,
      selection: Binding(
        get: { Self.date(minutes: binding.wrappedValue) },
        set: { binding.wrappedValue = Self.minutes(of: $0) }),
      displayedComponents: .hourAndMinute
    )
    .datePickerStyle(.stepperField)
    .labelsHidden()
    .fixedSize()
  }

  static func date(minutes: Int, calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))
      ?? Date(timeIntervalSinceReferenceDate: 0)
  }

  static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  }
}

// MARK: - Saved playlist

private struct DisplaysPlanRow: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let plans = controller.playlistPlanRows
    let inUse = plans.first { $0.id == state.playlist.planID }
    if model.planEditor == .save(display: display.id) {
      DisplaysNameFormRow(
        form: Binding(get: { model.planName }, set: { model.planName = $0 }),
        label: L("Playlist name"), canSubmit: model.planName.canSubmit,
        cancel: { model.cancelPlanEditor() },
        submit: {
          controller.launch(PanelActionCoordinator.key("playlistPlanSave", id: display.id)) {
            try await model.submitPlanEditor()
          }
        })
    } else {
      DisplaysRow(
        item: DisplaysSettingsSection.playlistPlan, note: note(inUse), forced: forced,
        identity: display.id, labelsControl: false, stacked: true
      ) {
        HStack(spacing: 8) {
          DisplaysTitleMenu(
            selection: model.binding(
              PanelActionCoordinator.key("playlistPlanApply", id: display.id),
              current: inUse?.id ?? ""
            ) { id in
              // The blank entry is a prompt, not a plan: it applies nothing.
              guard !id.isEmpty else { return }
              try await controller.applyPlaylistPlan(id, display: display.id)
            },
            title: inUse?.name
              ?? (plans.isEmpty ? L("No saved playlists yet") : L("Choose a saved playlist…")),
            width: 360, alignment: .leading, fitsTitle: true
          ) {
            if plans.isEmpty {
              Text("No saved playlists yet").tag("")
            } else {
              Text("Choose a saved playlist…").tag("")
              ForEach(plans) { Text(verbatim: $0.name).tag($0.id) }
            }
          }
          .disabled(off || plans.isEmpty)
          .accessibilityLabel(Text(verbatim: L("Saved playlist for \(display.title)")))
          Spacer(minLength: 0)
          Button("Save as…") { model.beginSavingPlan(of: display.id) }
            .disabled(off || state.playlist.mode == .off)
        }
      }
    }
  }

  private func note(_ inUse: PlaylistPlanRow?) -> String {
    if let inUse {
      return L(
        "Using “\(inUse.name)”. Changing a setting above keeps this display’s copy and detaches it from the saved playlist."
      )
    }
    if state.playlist.mode == .off {
      return L("Turn the playlist on to save it, or apply a saved one.")
    }
    return L(
      "Applying a saved playlist copies its settings to this display. Save as… keeps the settings above under a name."
    )
  }
}
