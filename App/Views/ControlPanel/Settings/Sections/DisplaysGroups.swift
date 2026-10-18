import SwiftUI

// MARK: - Display layouts

/// Display layouts: the arrangements of wallpapers saved for the enabled independent displays, each
/// applied in one step. The result of a layout, copy or swap action is a status line VoiceOver
/// reads out, and a failure is a box that takes focus.
///
/// A saved layout is a search unit of its own (`DisplaysSearchUnits`): its name, what goes where and
/// why it cannot be applied find it.
struct DisplaysLayoutsGroup: View {
  @Environment(PanelController.self) private var controller
  @FocusState private var focus: DisplaysSettingsModel.LayoutFocus?

  var body: some View {
    let model = controller.displaysSettings
    let state = controller.displayLayoutsState
    let settings = controller.settings
    let locked = controller.isStoreBusy
    let groupMatches = settings.search.matches(settings.text(DisplaysSettingsSection.layouts.title ?? ""))
    let showsSave = groupMatches || settings.search.shows(DisplaysSettingsSection.layoutsSave)
    let error = model.layoutError ?? state.loadError
    SettingsGroup(DisplaysSettingsSection.layouts, in: .displays) {
      DisplaysItemNote(item: DisplaysSettingsSection.layoutsSave, forced: groupMatches)
      if state.layouts.isEmpty && showsSave {
        DisplaysNote(text: L("No saved layouts yet. Arrange your wallpapers, then save the layout."))
      }
      ForEach(state.layouts) { layout in
        if groupMatches || settings.search.matches(DisplaysSearchUnits.text(of: layout)) {
          DisplaysLayoutRow(layout: layout, locked: locked, focus: $focus)
        }
      }
      if showsSave || model.layoutEditor == .new { saveRow(state: state, locked: locked) }
      if let error {
        DisplaysMessageRow(text: error, isError: true)
          .focusable()
          .focused($focus, equals: .error)
          .accessibilityIdentifier("displays.layout-error")
      } else if let status = model.layoutStatus {
        DisplaysMessageRow(text: status)
          .accessibilityIdentifier("displays.layout-status")
      }
    }
    .announcesChanges(of: error ?? model.layoutStatus)
    .onChange(of: model.layoutFocus, initial: true) { _, target in
      guard let target else { return }
      focus = target
      model.consumeLayoutFocus()
    }
  }

  /// Save current layout…, or the form that names it; at the limit, why Save is off.
  @ViewBuilder
  private func saveRow(state: DisplayLayoutsState, locked: Bool) -> some View {
    let model = controller.displaysSettings
    if model.layoutEditor == .new {
      DisplaysNameFormRow(
        form: Binding(get: { model.layoutName }, set: { model.layoutName = $0 }),
        label: L("Layout name"), canSubmit: model.layoutName.canSubmit,
        cancel: { model.cancelLayoutEditor() },
        submit: {
          controller.launch(PanelActionCoordinator.key("displayLayoutSave")) {
            await model.submitLayoutEditor()
          }
        })
    } else {
      HStack(spacing: 8) {
        Button("Save current layout…") { model.beginNewLayout() }
          .focused($focus, equals: .new)
          .disabled(locked || !state.canSave || state.isFull)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      if state.isFull {
        DisplaysNote(
          text: L("The limit of \(state.limit) layouts is reached. Delete one before saving another."),
          tone: .warning)
      }
    }
  }
}

/// A saved layout: its name, which wallpaper goes on which display, why it cannot be applied when it
/// cannot, and Apply, Rename… and Delete… beside it, as a saved playlist has. Delete asks first, in
/// the row.
private struct DisplaysLayoutRow: View {
  let layout: DisplayLayoutsState.Layout
  let locked: Bool
  var focus: FocusState<DisplaysSettingsModel.LayoutFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.displaysSettings
    Group {
      if model.layoutEditor == .rename(layout.id) {
        DisplaysNameFormRow(
          form: Binding(get: { model.layoutName }, set: { model.layoutName = $0 }),
          label: L("Layout name"), canSubmit: model.layoutName.canSubmit,
          cancel: { model.cancelLayoutEditor() },
          submit: {
            controller.launch(PanelActionCoordinator.key("displayLayoutRename", id: layout.id)) {
              await model.submitLayoutEditor()
            }
          })
      } else if model.layoutDeleteArmed == layout.id {
        DisplaysRowLayout {
          Text("Delete “\(layout.name)”? Current wallpapers stay as they are.")
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            Button("Cancel") { model.cancelDelete() }
            Button("Delete") {
              controller.launch(PanelActionCoordinator.key("displayLayoutDelete", id: layout.id)) {
                await model.deleteLayout(layout.id)
              }
            }
            .foregroundStyle(theme.surface.danger.color)
            .focused(focus, equals: .confirmDelete(layout.id))
            .disabled(locked)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        // The confirmation is one group, named as the page named it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: L("Delete layout")))
      } else {
        DisplaysRowLayout {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: layout.name)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            ForEach(layout.assignments.indices, id: \.self) { index in
              let assignment = layout.assignments[index]
              Text(verbatim: L("\(assignment.displayTitle): \(assignment.wallpaperTitle)"))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.surface.muted.color)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if let reason = layout.unavailableReason {
              Text(verbatim: reason)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.surface.warning.color)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            Button("Apply") {
              controller.launch(PanelActionCoordinator.key("displayLayoutApply", id: layout.id)) {
                await model.applyLayout(layout.id)
              }
            }
            .accessibilityLabel(Text(verbatim: L("Apply layout “\(layout.name)”")))
            .focused(focus, equals: .apply(layout.id))
            .disabled(locked || layout.unavailableReason != nil)
            Button("Rename…") { model.beginRenaming(layout) }
              .accessibilityLabel(Text(verbatim: L("Rename layout “\(layout.name)”")))
              .focused(focus, equals: .rename(layout.id))
              .disabled(locked)
            Button("Delete…") { model.askToDelete(layout.id) }
              .accessibilityLabel(Text(verbatim: L("Delete layout “\(layout.name)”")))
              .focused(focus, equals: .delete(layout.id))
              .disabled(locked)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.layout.\(layout.id)")
  }
}

// MARK: - Saved playlists

/// Saved playlists: the named copies of a display's playlist that any display can take. Renaming asks
/// for a name in the row; deleting asks first, and tells the displays that use the playlist keep theirs.
struct DisplaysPlansGroup: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @FocusState private var focus: DisplaysSettingsModel.PlanFocus?

  var body: some View {
    let model = controller.displaysSettings
    let plans = controller.playlistPlanRows
    SettingsGroup(DisplaysSettingsSection.plans, in: .displays) {
      if plans.isEmpty {
        DisplaysNote(
          text: L("No saved playlists yet. Set up a display’s playlist above, then choose Save as…."))
      }
      // The rows are not units of the search: the group is found by its title or by the Saved
      // playlist rows on the displays.
      ForEach(plans) { plan in DisplaysPlanRowView(plan: plan, focus: $focus) }
    }
    .onChange(of: model.planFocus, initial: true) { _, target in
      guard let target else { return }
      focus = target
      model.consumePlanFocus()
    }
  }
}

private struct DisplaysPlanRowView: View {
  let plan: PlaylistPlanRow
  var focus: FocusState<DisplaysSettingsModel.PlanFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.displaysSettings
    let locked = controller.isStoreBusy
    Group {
      if model.planEditor == .rename(plan.id) {
        DisplaysNameFormRow(
          form: Binding(get: { model.planName }, set: { model.planName = $0 }),
          label: L("Playlist name"), canSubmit: model.planName.canSubmit,
          cancel: { model.cancelPlanEditor() },
          submit: {
            controller.launch(PanelActionCoordinator.key("playlistPlanRename", id: plan.id)) {
              try await model.submitPlanEditor()
            }
          })
      } else if model.planDeleteArmed == plan.id {
        DisplaysRowLayout {
          Group {
            if plan.displayCount > 0 {
              Text("Delete “\(plan.name)”? Displays using it keep their current playlist.")
            } else {
              Text("Delete “\(plan.name)”?")
            }
          }
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            Button("Cancel") { model.cancelPlanDelete() }
            Button("Delete") {
              controller.launch(PanelActionCoordinator.key("playlistPlanDelete", id: plan.id)) {
                try await model.deletePlan(plan.id)
              }
            }
            .foregroundStyle(theme.surface.danger.color)
            .focused(focus, equals: .confirmDelete(plan.id))
            .disabled(locked)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
      } else {
        DisplaysRowLayout {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: plan.name)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            Text(verbatim: summary)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            Button("Rename…") { model.beginRenaming(plan) }
              .focused(focus, equals: .rename(plan.id))
              .disabled(locked)
            Button("Delete…") { model.askToDeletePlan(plan.id) }
              .focused(focus, equals: .delete(plan.id))
              .disabled(locked)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.plan.\(plan.id)")
  }

  /// What the plan does, and on how many displays.
  private var summary: String {
    let what = DisplaysPlanSummary.text(
      of: plan.playlist,
      collectionName: { controller.collections.collection(id: $0)?.name },
      wallpaperTitle: { id in controller.store.librarySnapshot.wallpapers.first { $0.id == id }?.title })
    switch plan.displayCount {
    case 0: return what
    case 1: return "\(what) · \(L("On 1 display"))"
    default: return "\(what) · \(L("On \(plan.displayCount) displays"))"
    }
  }
}

// MARK: - Sunrise and sunset

/// Sunrise and sunset: the coordinates the sun rules of the time schedule are calculated from. They
/// are saved on this Mac and used locally; nothing is looked up.
struct DisplaysSolarGroup: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.displaysSettings
    let saved = controller.solarLocation
    let busy = controller.isStoreBusy
    let latitude = Binding(
      get: { model.latitudeText ?? saved.map { DisplaysNumberInput.text($0.latitude, digits: 6, locale: locale) } ?? "" },
      set: { model.latitudeText = $0 })
    let longitude = Binding(
      get: { model.longitudeText ?? saved.map { DisplaysNumberInput.text($0.longitude, digits: 6, locale: locale) } ?? "" },
      set: { model.longitudeText = $0 })
    let canSave = Self.isValid(latitude.wrappedValue, within: -90...90, locale: locale)
      && Self.isValid(longitude.wrappedValue, within: -180...180, locale: locale)
    SettingsGroup(DisplaysSettingsSection.solar, in: .displays) {
      if let error = controller.automationLoadError {
        DisplaysMessageRow(text: error, isError: true)
      }
      DisplaysRow(item: DisplaysSettingsSection.solarSource) {
        Picker(
          noLabel,
          selection: Binding(
            get: { model.solarSource },
            set: { source in
              controller.launch(PanelActionCoordinator.key("automationSolarSource")) {
                try await model.setSolarSource(source)
              }
            })
        ) {
          Text("Coordinates").tag(WallpaperSolarSource.coordinates)
          Text("Fixed times").tag(WallpaperSolarSource.fixed)
          Text("Automatic").tag(WallpaperSolarSource.automatic)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(busy)
      }
      switch model.solarSource {
      case .coordinates:
        DisplaysItemNote(item: DisplaysSettingsSection.solarIntro)
        DisplaysRow(item: DisplaysSettingsSection.solarIntro, note: "") {
          coordinateField(latitude, busy: busy, canSave: canSave)
        }
        DisplaysRow(item: DisplaysSettingsSection.solarLongitude) {
          coordinateField(longitude, busy: busy, canSave: canSave)
        }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          if saved != nil {
            Button("Clear location") {
              controller.launch(PanelActionCoordinator.key("automationClearLocation")) {
                try await model.clearLocation()
              }
            }
            .disabled(busy)
          }
          Button("Save location") { save() }
            .buttonStyle(.panelPrimary(size: .small))
            .disabled(busy || !canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      case .fixed:
        DisplaysRow(item: DisplaysSettingsSection.solarSunrise) {
          DisplaysClockField(
            binding: Binding(
              get: { model.solarSunriseMinute },
              set: { minute in
                controller.launch(
                  PanelActionCoordinator.key("automationSolarTimes"), policy: .latestWins
                ) {
                  try await model.setSolarFixedTimes(sunrise: minute, sunset: nil)
                }
              }))
        }
        DisplaysRow(item: DisplaysSettingsSection.solarSunset) {
          DisplaysClockField(
            binding: Binding(
              get: { model.solarSunsetMinute },
              set: { minute in
                controller.launch(
                  PanelActionCoordinator.key("automationSolarTimes"), policy: .latestWins
                ) {
                  try await model.setSolarFixedTimes(sunrise: nil, sunset: minute)
                }
              }))
        }
      case .automatic:
        DisplaysRow(item: DisplaysSettingsSection.solarActions, note: model.solarAutomaticStatus) {
          if model.solarLocationDenied {
            Button("Open Location Settings") {
              controller.launch(PanelActionCoordinator.key("automationSolarSettings")) {
                try await controller.showSolarLocationSettings()
              }
            }
            .disabled(busy)
          } else {
            Button("Use current location") {
              controller.launch(PanelActionCoordinator.key("automationSolarLocate")) {
                try await model.startAutomaticLocation()
              }
            }
            .disabled(busy)
          }
        }
      }
      DisplaysNote(text: L("Solar times are approximate. Near the poles, a day may have no sunrise or sunset."))
    }
  }

  private func coordinateField(_ text: Binding<String>, busy: Bool, canSave: Bool) -> some View {
    TextField(noLabel, text: text)
      .textFieldStyle(.roundedBorder)
      .font(.system(size: 12.5).monospacedDigit())
      .multilineTextAlignment(.trailing)
      .frame(width: 110)
      .onSubmit { if canSave { save() } }
      .disabled(busy)
  }

  private func save() {
    controller.launch(PanelActionCoordinator.key("automationLocation")) {
      try await controller.displaysSettings.saveLocation()
    }
  }

  /// Whether a coordinate field holds a number in its range.
  static func isValid(_ text: String, within range: ClosedRange<Double>, locale: Locale) -> Bool {
    DisplaysNumberInput.parse(text, locale: locale).map(range.contains) ?? false
  }
}
