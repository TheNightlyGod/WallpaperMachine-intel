import SwiftUI

/// A display's Automatic wallpaper selection disclosure: off, a time schedule, the system
/// appearance or a wallpaper for each desktop chooses its wallpaper. A mirrored or disabled display shows it
/// but cannot change it.
struct DisplaysAutomationDisclosure: View {
  let display: DisplayRow
  let card: DisplaysCardSearch

  var body: some View {
    DisplaysDisclosure(
      item: DisplaysSettingsSection.automation, display: display.id, card: card
    ) {
      DisplaysAutomationRows(display: display, forced: card.forced)
    }
  }
}

/// The rows inside the disclosure. Built only while it is open, so a closed one reads nothing.
private struct DisplaysAutomationRows: View {
  let display: DisplayRow
  let forced: Bool

  @Environment(PanelController.self) private var controller
  @FocusState private var focus: DisplaysSettingsModel.AutomationFocus?

  var body: some View {
    let model = controller.displaysSettings
    let state = controller.automationState(for: display.id)
    let targets = controller.automationTargets
    let locked = controller.isStoreBusy || !display.enabled || display.isMirror
    let title = { (item: SettingsItem) in
      L("\(controller.settings.text(item.title)) for \(display.title)")
    }
    Group {
      DisplaysRow(
        item: DisplaysSettingsSection.automationMode, note: modeNote(state), forced: forced,
        identity: display.id, controlLabel: L("Automatic changes for \(display.title)")
      ) {
        let mode = model.binding(
          PanelActionCoordinator.key("automationMode", id: display.id), current: state.mode
        ) { mode in try await controller.setAutomationMode(mode, display: display.id) }
        DisplaysTitleMenu(
          selection: mode,
          title: {
            switch mode.wrappedValue {
            case .off: L("Off")
            case .schedule: L("Time schedule")
            case .appearance: L("Follow system appearance")
            case .spaces: L("Different wallpaper for each desktop")
            }
          }(), width: 210
        ) {
          Text("Off").tag(DisplayWallpaperAutomation.Mode.off)
          Text("Time schedule").tag(DisplayWallpaperAutomation.Mode.schedule)
          Text("Follow system appearance").tag(DisplayWallpaperAutomation.Mode.appearance)
          Text("Different wallpaper for each desktop").tag(DisplayWallpaperAutomation.Mode.spaces)
            .disabled(!state.spacesAvailable)
        }
        .focused($focus, equals: .modePicker(display: display.id))
        .disabled(locked)
      }

      switch state.mode {
      case .off:
        EmptyView()
      case .appearance:
        DisplaysRow(
          item: DisplaysSettingsSection.automationLight, forced: forced, identity: display.id,
          controlLabel: title(DisplaysSettingsSection.automationLight)
        ) {
          DisplaysTargetPicker(
            selection: state.light, targets: targets, isRequired: false,
            key: PanelActionCoordinator.key("automationAppearance", id: display.id, detail: "light"),
            commit: { try await controller.setAutomationAppearance(.light, to: $0, display: display.id) }
          )
          .disabled(locked)
        }
        DisplaysRow(
          item: DisplaysSettingsSection.automationDark, forced: forced, identity: display.id,
          controlLabel: title(DisplaysSettingsSection.automationDark)
        ) {
          DisplaysTargetPicker(
            selection: state.dark, targets: targets, isRequired: false,
            key: PanelActionCoordinator.key("automationAppearance", id: display.id, detail: "dark"),
            commit: { try await controller.setAutomationAppearance(.dark, to: $0, display: display.id) }
          )
          .disabled(locked)
        }
      case .spaces:
        // The desktops are chosen on the card itself, where the switch is.
        DisplaysNote(text: L("Each desktop’s wallpaper is chosen above, under Different wallpaper for each desktop."))
      case .schedule:
        DisplaysScheduleRows(
          display: display, state: state, targets: targets, locked: locked, forced: forced,
          focus: $focus)
      }

      DisplaysAutomationFooter(display: display, state: state, locked: locked, forced: forced)
    }
    .onChange(of: model.automationFocus, initial: true) { _, target in
      switch target {
      case nil, .desktopsToggle, .forget:
        // The desktop rows take their own focus.
        break
      case let target?:
        focus = target
        model.consumeAutomationFocus()
      }
    }
  }

  /// "Manual choices stay until the next rule changes them." and, when a wallpaper for each desktop
  /// cannot be chosen, why.
  private func modeNote(_ state: AutomationState) -> String {
    let base = L("Manual choices stay until the next rule changes them.")
    guard state.mode != .spaces, let reason = state.spacesUnavailableReason else { return base }
    switch reason {
    case .lockScreenOwnsDesktop:
      return "\(base) \(L("Turn off animated lock-screen wallpaper to use desktop Space choices."))"
    case .noInformation:
      return
        "\(base) \(L("Desktop information is unavailable. Refresh Spaces or choose another automatic mode."))"
    }
  }
}

// MARK: - Choosing a wallpaper or a saved playlist

/// A menu of what an automatic choice can switch to: the wallpapers that can play, then the saved
/// playlists. A saved choice that no longer resolves stays in the menu as "Unavailable", so the menu
/// shows it and does not change it.
struct DisplaysTargetPicker: View {
  let selection: WallpaperAutomationTarget?
  let targets: AutomationTargets
  /// A required choice has no "Leave as it is" entry and asks for a choice instead.
  let isRequired: Bool
  let key: String
  let commit: @MainActor (WallpaperAutomationTarget?) async throws -> Void
  /// Called with the chosen target instead of acting on it, for the editor's draft.
  var onSelect: ((WallpaperAutomationTarget?) -> Void)?
  /// How wide the menu is: its entries are the user's own titles and may be long.
  var width: CGFloat = 200
  /// Where the menu sits in its width: at the trailing edge of a row, the leading edge of a form's
  /// column.
  var alignment = Alignment.trailing

  @Environment(PanelController.self) private var controller

  var body: some View {
    let current = Self.identifier(selection)
    let resolves = selection.map { targets.title(of: $0) != nil } ?? true
    DisplaysTitleMenu(
      selection: Binding(
        get: { controller.displaysSettings.drafts[key] as? String ?? current },
        set: { chosen in
          let target = Self.target(chosen, in: targets, keeping: selection)
          if let onSelect {
            onSelect(target)
          } else {
            controller.displaysSettings.setDraft(key, to: chosen)
            controller.launch(key) {
              defer { controller.displaysSettings.setDraft(key, to: nil) }
              try await commit(target)
            }
          }
        }),
      title: title(for: controller.displaysSettings.drafts[key] as? String ?? current, resolves: resolves),
      width: width, alignment: alignment
    ) {
      if isRequired {
        Text("Choose a wallpaper or saved playlist").tag("")
      } else {
        Text("Leave as it is").tag("")
      }
      if !resolves, let selection {
        Text("Unavailable").tag(Self.identifier(selection))
      }
      if !targets.wallpapers.isEmpty {
        Section("Wallpapers") {
          ForEach(targets.wallpapers) { Text(verbatim: $0.title).tag($0.id) }
        }
      }
      if !targets.playlists.isEmpty {
        Section("Saved playlists") {
          ForEach(targets.playlists) { Text(verbatim: $0.title).tag($0.id) }
        }
      }
    }
  }

  /// The title of the choice shown: what it is, "Unavailable" when it no longer resolves, or what
  /// asks for a choice.
  private func title(for identifier: String, resolves: Bool) -> String {
    if identifier.isEmpty { return isRequired ? L("Choose a wallpaper or saved playlist") : L("Leave as it is") }
    if let found = (targets.wallpapers + targets.playlists).first(where: { $0.id == identifier }) { return found.title }
    return L("Unavailable")
  }

  /// The kind and the id as one tag; "" for no choice.
  static func identifier(_ target: WallpaperAutomationTarget?) -> String {
    target.map { "\($0.kind.rawValue):\($0.id)" } ?? ""
  }

  /// The target a tag stands for. A saved choice that no longer resolves keeps its own target.
  static func target(
    _ identifier: String, in targets: AutomationTargets, keeping saved: WallpaperAutomationTarget?
  ) -> WallpaperAutomationTarget? {
    guard !identifier.isEmpty else { return nil }
    if let saved, Self.identifier(saved) == identifier { return saved }
    return (targets.wallpapers + targets.playlists).first { $0.id == identifier }?.target
  }
}

// MARK: - Time schedule

private struct DisplaysScheduleRows: View {
  let display: DisplayRow
  let state: AutomationState
  let targets: AutomationTargets
  let locked: Bool
  let forced: Bool
  var focus: FocusState<DisplaysSettingsModel.AutomationFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// A display keeps at most this many rules.
  private static let ruleLimit = 64

  var body: some View {
    let model = controller.displaysSettings
    let editing = model.ruleEditorDisplay == display.id ? model.ruleEditor : nil
    if state.rules.isEmpty && editing == nil {
      DisplaysNote(text: L("No time rules yet. Add one to choose when this display changes."))
    }
    ForEach(state.rules) { rule in
      if let editing, editing.id == rule.id {
        DisplaysRuleEditor(display: display, targets: targets, focus: focus)
      } else {
        ruleRow(rule)
      }
    }
    if let editing, editing.id == nil {
      DisplaysRuleEditor(display: display, targets: targets, focus: focus)
    }
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button("Add time rule") { model.beginRule(display: display.id) }
          .focused(focus, equals: .addRule(display: display.id))
          .disabled(locked || state.rules.count >= Self.ruleLimit || editing != nil)
        Spacer(minLength: 0)
        if let next = state.next {
          Text(verbatim: nextLine(next))
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
        }
      }
      DisplaysCaption(item: DisplaysSettingsSection.automationSchedule, forced: forced)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func ruleRow(_ rule: WallpaperAutomationRule) -> some View {
    let model = controller.displaysSettings
    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: targets.title(of: rule.target) ?? L("Unavailable"))
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(verbatim: DisplaysRuleSummary.text(of: rule))
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Edit…") { model.beginRule(display: display.id, editing: rule) }
        .focused(focus, equals: .editRule(display: display.id, id: rule.id))
        .disabled(locked)
      Button("Remove") {
        controller.launch(
          PanelActionCoordinator.key("automationRuleRemove", id: display.id, detail: rule.id)
        ) { try await model.removeRule(rule.id, display: display.id) }
      }
      .disabled(locked)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.automation-rule.\(display.id).\(rule.id)")
  }

  /// "Next: Evening at Fri 18:30".
  private func nextLine(_ date: Date) -> String {
    let locale = PanelLocale.shared.locale
    let time = date.formatted(
      Date.FormatStyle(locale: locale).weekday(.abbreviated).hour(.twoDigits(amPM: .abbreviated))
        .minute(.twoDigits))
    let name = state.nextTarget.flatMap { targets.title(of: $0) } ?? L("Unavailable")
    return L("Next: \(name) at \(time)")
  }
}

/// What a time rule says on one line: when, which days and the offset from the sun.
enum DisplaysRuleSummary {
  /// The Gregorian weekday numbers, Sunday first, and their short names.
  @MainActor static func shortName(of weekday: Int) -> String {
    switch weekday {
    case 1: L("Sun")
    case 2: L("Mon")
    case 3: L("Tue")
    case 4: L("Wed")
    case 5: L("Thu")
    case 6: L("Fri")
    default: L("Sat")
    }
  }

  @MainActor static func fullName(of weekday: Int) -> String {
    switch weekday {
    case 1: L("Sunday")
    case 2: L("Monday")
    case 3: L("Tuesday")
    case 4: L("Wednesday")
    case 5: L("Thursday")
    case 6: L("Friday")
    default: L("Saturday")
    }
  }

  /// "Every day · 08:00", "Mon, Tue · Sunrise · 20 min before".
  @MainActor
  static func text(of rule: WallpaperAutomationRule) -> String {
    let days =
      rule.weekdays.count == 7
      ? L("Every day") : rule.weekdays.sorted().map(shortName(of:)).joined(separator: ", ")
    let when: String
    switch rule.event {
    case .time: when = ClockMinute(minutes: rule.minute)?.text ?? ""
    case .sunrise: when = L("Sunrise")
    case .sunset: when = L("Sunset")
    }
    var parts = [days, when]
    if rule.event != .time, rule.offset != 0 {
      parts.append(
        rule.offset < 0 ? L("\(abs(rule.offset)) min before") : L("\(rule.offset) min after"))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - The rule editor

/// The inline form that adds a time rule or edits one: when, the time or the offset from the sun,
/// the days, and what to switch to. A rule needs a target and at least one day; the form says so
/// instead of saving.
private struct DisplaysRuleEditor: View {
  let display: DisplayRow
  let targets: AutomationTargets
  var focus: FocusState<DisplaysSettingsModel.AutomationFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.displaysSettings
    let draft = Binding(get: { model.ruleEditor ?? DisplaysRuleDraft() }, set: { model.ruleEditor = $0 })
    let value = draft.wrappedValue
    VStack(alignment: .leading, spacing: 10) {
      formRow(L("When")) {
        DisplaysTitleMenu(
          selection: draft.event,
          title: {
            switch value.event {
            case .time: L("At a time")
            case .sunrise: L("Sunrise")
            case .sunset: L("Sunset")
            }
          }(), width: 150, alignment: .leading
        ) {
          Text("At a time").tag(WallpaperAutomationRule.Event.time)
          Text("Sunrise").tag(WallpaperAutomationRule.Event.sunrise)
          Text("Sunset").tag(WallpaperAutomationRule.Event.sunset)
        }
        // The editor opens with the keyboard on its first control.
        .focused(focus, equals: .ruleEvent(display: display.id))
      }
      if value.event == .time {
        formRow(L("Time")) {
          DisplaysClockField(
            binding: Binding(
              get: { draft.wrappedValue.time.minutes },
              set: { draft.wrappedValue.time = ClockMinute(minutes: $0) ?? draft.wrappedValue.time }))
        }
      } else {
        formRow(L("Offset in minutes")) {
          TextField(noLabel, text: draft.offsetText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .accessibilityLabel(Text(verbatim: L("Offset in minutes")))
        }
        Text("Negative offsets run before the sun event; positive offsets run after it. Set your location below.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
      }
      formRow(L("Repeat on")) {
        VStack(alignment: .leading, spacing: 6) {
          // The days and the quick sets wrap at the width the form has: seven buttons in one line
          // are wider than the narrowest window's page.
          TagFlow(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
              if day == 1 {
                dayToggle(day, draft: draft).focused(focus, equals: .firstDay)
              } else {
                dayToggle(day, draft: draft)
              }
            }
          }
          TagFlow(spacing: 6) {
            Button("Weekdays") { draft.wrappedValue.choose(AutomationRuleEdit.weekdaysOnly) }
            Button("Weekends") { draft.wrappedValue.choose(AutomationRuleEdit.weekends) }
            Button("Every day") { draft.wrappedValue.choose(AutomationRuleEdit.everyDay) }
          }
          if value.showsDaysError {
            Text("Choose at least one weekday.")
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.danger.color)
          }
        }
      }
      formRow(L("Switch to")) {
        DisplaysTargetPicker(
          selection: value.target, targets: targets, isRequired: true,
          key: PanelActionCoordinator.key("automationRuleDraft", id: display.id),
          commit: { _ in }, onSelect: { draft.wrappedValue.target = $0 }, width: 300,
          alignment: .leading)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Cancel") { model.cancelRule() }
        Button("Save rule") {
          controller.launch(PanelActionCoordinator.key("automationRuleSave", id: display.id)) {
            try await model.saveRule()
          }
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(!value.canSave(locale: locale))
      }
    }
    .announcesChanges(of: value.showsDaysError ? L("Choose at least one weekday.") : nil)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(theme.surface.hover.color)
    .onExitCommand { model.cancelRule() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.automation-editor.\(display.id)")
  }

  private func dayToggle(_ day: Int, draft: Binding<DisplaysRuleDraft>) -> some View {
    Toggle(
      isOn: Binding(
        get: { draft.wrappedValue.weekdays.contains(day) },
        set: { _ in draft.wrappedValue.toggle(day) })
    ) {
      Text(verbatim: DisplaysRuleSummary.shortName(of: day)).frame(minWidth: 28)
    }
    .toggleStyle(.button)
    .accessibilityLabel(Text(verbatim: DisplaysRuleSummary.fullName(of: day)))
  }

  /// A label and what it labels: side by side while there is room, the label above otherwise.
  private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    DisplaysRowLayout(spacing: 12, fillsControl: true) {
      Text(verbatim: title)
        .font(.system(size: 13))
        .frame(width: 112, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Footer

private struct DisplaysAutomationFooter: View {
  let display: DisplayRow
  let state: AutomationState
  let locked: Bool
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    if state.isFocused {
      DisplaysNote(text: L("A Focus filter is active for this display. Manual choices remain available."))
    }
    if let error = state.error {
      DisplaysMessageRow(text: error, isError: true)
      HStack {
        Button("Retry automatic change") {
          controller.launch(PanelActionCoordinator.key("automationRetry", id: display.id)) {
            try await controller.retryAutomation(display: display.id)
          }
        }
        .disabled(locked)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
    VStack(alignment: .leading, spacing: 8) {
      DisplaysCaption(item: DisplaysSettingsSection.automationFooter, forced: forced)
      HStack(spacing: 8) {
        Button("Refresh Spaces") {
          controller.launch(PanelActionCoordinator.key("automationRefreshSpaces")) {
            try await controller.refreshSpaces()
          }
        }
        Button("Open Focus Settings…") {
          controller.launch(PanelActionCoordinator.key("openFocusSettings")) {
            try await controller.openFocusSettings()
          }
        }
        Spacer(minLength: 0)
      }
      .disabled(locked)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .announcesChanges(of: state.error)
  }
}
