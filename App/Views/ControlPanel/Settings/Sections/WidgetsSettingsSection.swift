import AppKit
import SwiftUI

/// Settings › Desktop Widgets: clocks, dates, notes, countdowns and the other widgets the app draws on
/// the desktop over any wallpaper. A widget
/// belongs to no wallpaper, so changing the wallpaper keeps it, and none of its controls waits for
/// the renderer. The list picks the widget the groups below edit; the preview arranges it by drag,
/// and the position sliders do the same from the keyboard and VoiceOver.
struct WidgetsSettingsSection: View {
  private static let list = SettingsItem.Group("widgets")
  private static let arrange = SettingsItem.Group("arrange", title: "Position")
  private static let look = SettingsItem.Group("look", title: "Look")
  private static let format = SettingsItem.Group("format", title: "Format")
  private static let removal = SettingsItem.Group("remove")

  static let add = SettingsItem(
    id: "widgets.add", section: .widgets, group: list, title: "Add a widget",
    note:
      "Widgets stay on the desktop when you change the wallpaper. They sit above the wallpaper and below your desktop icons, on every desktop.",
    keywords: [
      "Add Widget", "Clock", "Date", "Text", "Countdown", "Greeting", "Battery", "Sunrise and sunset",
      "Analog clock", "Month calendar",
    ])

  static let shown = SettingsItem(
    id: "widgets.shown", section: .widgets, group: arrange, title: "Show on the desktop")
  static let display = SettingsItem(
    id: "widgets.display", section: .widgets, group: arrange, title: "Display",
    keywords: ["Main display", "All displays"])
  static let preview = SettingsItem(
    id: "widgets.preview", section: .widgets, group: arrange, title: "Arrange",
    note: "Drag the widget to where you want it on the display.")
  static let horizontal = SettingsItem(
    id: "widgets.horizontal", section: .widgets, group: arrange, title: "Horizontal position")
  static let vertical = SettingsItem(
    id: "widgets.vertical", section: .widgets, group: arrange, title: "Vertical position")
  static let alignment = SettingsItem(
    id: "widgets.alignment", section: .widgets, group: arrange, title: "Alignment",
    note: "The edge of the text that stays in place when the text gets longer or shorter.",
    keywords: ["Left", "Center", "Right"])

  static let size = SettingsItem(id: "widgets.size", section: .widgets, group: look, title: "Size")
  static let typeface = SettingsItem(
    id: "widgets.typeface", section: .widgets, group: look, title: "Typeface",
    keywords: ["Standard", "Rounded", "Serif", "Monospaced"])
  static let weight = SettingsItem(
    id: "widgets.weight", section: .widgets, group: look, title: "Weight",
    note: "From 100, the thinnest, through 400, regular, to 900, the boldest.")
  static let color = SettingsItem(id: "widgets.color", section: .widgets, group: look, title: "Color")
  static let opacity = SettingsItem(
    id: "widgets.opacity", section: .widgets, group: look, title: "Opacity")
  static let shadow = SettingsItem(
    id: "widgets.shadow", section: .widgets, group: look, title: "Shadow",
    note: "Keeps light text readable on a light wallpaper.")

  static let timeFormat = SettingsItem(
    id: "widgets.time-format", section: .widgets, group: format, title: "Time format",
    keywords: ["Follow system", "12-hour", "24-hour"])
  static let seconds = SettingsItem(
    id: "widgets.seconds", section: .widgets, group: format, title: "Show seconds",
    note: "The clock is redrawn every second instead of every minute.")
  static let dateFormat = SettingsItem(
    id: "widgets.date-format", section: .widgets, group: format, title: "Date format")
  static let calendarSystem = SettingsItem(
    id: "widgets.calendar", section: .widgets, group: format, title: "Calendar",
    note: "Writes the date in another calendar, such as the Chinese lunar calendar.")
  static let timeZone = SettingsItem(
    id: "widgets.time-zone", section: .widgets, group: format, title: "Time zone",
    note: "Shows the time in another city instead of this Mac’s time zone.")
  static let label = SettingsItem(
    id: "widgets.label", section: .widgets, group: format, title: "Label",
    note: "Words shown before the time or date, such as a city’s name.")
  static let content = SettingsItem(
    id: "widgets.text", section: .widgets, group: format, title: "Text",
    note: "Press Option-Return for a new line.")
  static let event = SettingsItem(
    id: "widgets.event", section: .widgets, group: format, title: "Event",
    note: "Leave it empty to name the day instead.")
  static let targetDay = SettingsItem(
    id: "widgets.target-day", section: .widgets, group: format, title: "Count down to")
  static let name = SettingsItem(
    id: "widgets.name", section: .widgets, group: format, title: "Your name",
    note: "Added to the greeting when you give one.")
  static let sunStyle = SettingsItem(
    id: "widgets.sun", section: .widgets, group: format, title: "Sun times",
    note: "Uses the location set in Settings › Displays › Sunrise and sunset.",
    keywords: ["Next sunrise or sunset", "Today’s sunrise and sunset"])

  static let remove = SettingsItem(
    id: "widgets.remove", section: .widgets, group: removal, title: "Remove this widget",
    keywords: ["Remove"])

  /// The rows that edit the selected widget.
  static let editorItems = [
    shown, display, preview, horizontal, vertical, alignment, size, typeface, weight, color, opacity,
    shadow, timeFormat, seconds, dateFormat, calendarSystem, timeZone, label, content, event, targetDay, name,
    sunStyle, remove,
  ]
  static let items = [add] + editorItems

  /// The rows only some kinds of widget have, and those kinds.
  static let kindRows: [String: Set<DesktopWidget.Kind>] = [
    typeface.id: Set(DesktopWidget.Kind.allCases).subtracting([.analog]),
    timeFormat.id: [.time, .sun], seconds.id: [.time, .analog], dateFormat.id: [.date],
    calendarSystem.id: [.date], timeZone.id: [.time, .date, .analog], label.id: [.time, .date],
    content.id: [.text], event.id: [.countdown], targetDay.id: [.countdown], name.id: [.greeting],
    sunStyle.id: [.sun],
  ]

  /// The editor's rows while there is no widget to edit, and the rows the selected kind has not.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    guard let widget = controller.widgetsSettings.selected else { return Set(editorItems.map(\.id)) }
    return Set(kindRows.filter { !$0.value.contains(widget.kind) }.keys)
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.widgetsSettings
    let widgets = model.widgets
    let screens = model.screens()
    SettingsPage(.widgets) {
      SettingsGroup(Self.list, in: .widgets) {
        SettingsRow(Self.add) {
          addMenu
        }
        if !controller.settings.search.isActive {
          ForEach(widgets) { widget in
            WidgetListRow(widget: widget, screens: screens)
          }
        }
      }
      if let widget = model.selected {
        editor(widget, screens: screens)
      }
    }
  }

  /// The Add Widget menu: every kind, by name and symbol.
  private var addMenu: some View {
    let key = PanelActionCoordinator.key("addDesktopWidget")
    return Menu {
      ForEach(DesktopWidget.Kind.allCases, id: \.self) { kind in
        Button {
          controller.launch(key) { try await controller.addDesktopWidget(kind) }
        } label: {
          Label {
            Text(verbatim: Self.title(of: kind))
          } icon: {
            Image(systemName: Self.symbol(of: kind))
          }
        }
        .accessibilityIdentifier("widgets.add.\(kind.rawValue)")
      }
    } label: {
      Text("Add Widget")
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .disabled(controller.widgetsSettings.widgets.count >= DesktopWidgetStore.limit || controller.isBusy(key))
  }

  // MARK: The editor

  @ViewBuilder
  private func editor(_ widget: DesktopWidget, screens: [DesktopWidgetController.Screen]) -> some View {
    let model = controller.widgetsSettings
    let id = widget.id
    SettingsGroup(Self.arrange, in: .widgets) {
      SettingsRow(Self.shown) {
        WidgetSwitch(id: id, control: "shown", saved: widget.isShown) { .shown($0) }
      }
      SettingsRow(Self.display) {
        SettingsMenuControl(
          key: DesktopWidgetsSettingsModel.key(id, "placement"),
          saved: model.placementValue(for: widget, among: screens),
          options: model.placementOptions(for: widget, among: screens), waitsForMac: false,
          policy: .latestWins
        ) { try await controller.changeDesktopWidget(id, .placement($0)) }
      }
      if let screen = model.previewScreen(for: widget, among: screens) {
        SettingsRow(Self.preview, stacked: true) {
          DesktopWidgetPreview(screen: screen)
        }
      }
      SettingsRow(Self.horizontal) {
        percentSlider(id, "x", saved: widget.x) { .x($0) }
      }
      SettingsRow(Self.vertical) {
        percentSlider(id, "y", saved: widget.y) { .y($0) }
      }
      SettingsRow(Self.alignment) {
        SettingsSegmentedControl(
          segments: DesktopWidget.Alignment.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
          selection: model.value(id, "alignment", saved: widget.alignment), fillsWidth: false
        ) { value in
          model.commit(id, "alignment", to: value) { .alignment($0) }
        }
      }
    }
    SettingsGroup(Self.look, in: .widgets) {
      SettingsRow(Self.size) {
        SettingsSliderControl(
          key: DesktopWidgetsSettingsModel.key(id, "size"), saved: widget.size, range: DesktopWidget.sizeRange,
          waitsForMac: false, readout: { L("\($0) pt") }
        ) { try await controller.changeDesktopWidget(id, .size($0)) }
      }
      SettingsRow(Self.typeface) {
        SettingsMenuControl(
          key: DesktopWidgetsSettingsModel.key(id, "typeface"), saved: widget.typeface,
          options: DesktopWidget.Typeface.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
          waitsForMac: false, policy: .latestWins
        ) { try await controller.changeDesktopWidget(id, .typeface($0)) }
      }
      SettingsRow(Self.weight) {
        SettingsSliderControl(
          key: DesktopWidgetsSettingsModel.key(id, "weight"), saved: widget.weight / 100,
          range: (DesktopWidget.weightRange.lowerBound / 100)...(DesktopWidget.weightRange.upperBound / 100),
          waitsForMac: false, readout: { String($0 * 100) }
        ) { try await controller.changeDesktopWidget(id, .weight($0 * 100)) }
      }
      SettingsRow(Self.color) {
        WidgetColorControl(id: id, saved: widget.color)
      }
      SettingsRow(Self.opacity) {
        SettingsSliderControl(
          key: DesktopWidgetsSettingsModel.key(id, "opacity"), saved: widget.opacity,
          range: DesktopWidget.opacityRange, waitsForMac: false, readout: { L("\($0)%") }
        ) { try await controller.changeDesktopWidget(id, .opacity($0)) }
      }
      SettingsRow(Self.shadow) {
        WidgetSwitch(id: id, control: "shadow", saved: widget.hasShadow) { .shadow($0) }
      }
    }
    SettingsGroup(Self.format, in: .widgets) {
      switch widget.kind {
      case .time:
        SettingsRow(Self.timeFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "timeFormat"), saved: widget.timeFormat,
            options: DesktopWidget.TimeFormat.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .timeFormat($0)) }
        }
        SettingsRow(Self.seconds) {
          WidgetSwitch(id: id, control: "seconds", saved: widget.showsSeconds) { .showsSeconds($0) }
        }
        timeZoneRow(widget)
        labelRow(widget)
      case .date:
        SettingsRow(Self.dateFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "dateStyle"), saved: widget.dateStyle,
            options: model.dateStyleOptions(for: widget), waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .dateStyle($0)) }
        }
        SettingsRow(Self.calendarSystem) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "calendarSystem"), saved: widget.calendarSystem,
            options: model.calendarOptions(), waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .calendarSystem($0)) }
        }
        timeZoneRow(widget)
        labelRow(widget)
      case .analog:
        SettingsRow(Self.seconds) {
          WidgetSwitch(id: id, control: "seconds", saved: widget.showsSeconds) { .showsSeconds($0) }
        }
        timeZoneRow(widget)
      case .text:
        SettingsRow(Self.content) {
          WidgetTextField(id: id, saved: widget.text, multiline: true)
        }
      case .countdown:
        SettingsRow(Self.event) {
          WidgetTextField(id: id, saved: widget.text, multiline: false)
        }
        SettingsRow(Self.targetDay) {
          DatePicker(
            noLabel,
            selection: Binding(
              get: { model.targetDate(model.value(id, "targetDay", saved: widget.targetDay)) },
              set: { date in
                model.commit(id, "targetDay", to: DesktopWidget.day(of: date, in: .autoupdatingCurrent)) {
                  .targetDay($0)
                }
              }),
            displayedComponents: .date
          )
          .datePickerStyle(.stepperField)
          .labelsHidden()
          .fixedSize()
        }
      case .greeting:
        SettingsRow(Self.name) {
          WidgetTextField(id: id, saved: widget.text, multiline: false)
        }
      case .sun:
        SettingsRow(Self.sunStyle) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "sunStyle"), saved: widget.sunStyle,
            options: DesktopWidget.SunStyle.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .sunStyle($0)) }
        }
        SettingsRow(Self.timeFormat) {
          SettingsMenuControl(
            key: DesktopWidgetsSettingsModel.key(id, "timeFormat"), saved: widget.timeFormat,
            options: DesktopWidget.TimeFormat.allCases.map { .init(value: $0, title: Self.title(of: $0)) },
            waitsForMac: false, policy: .latestWins
          ) { try await controller.changeDesktopWidget(id, .timeFormat($0)) }
        }
      case .battery, .calendar:
        EmptyView()
      }
    }
    SettingsGroup(Self.removal, in: .widgets) {
      SettingsRow(Self.remove) {
        let key = PanelActionCoordinator.key("removeDesktopWidget", id: id)
        SettingsActionButton("Remove", isDisabled: controller.isBusy(key)) {
          controller.launch(key) { try await controller.removeDesktopWidget(id) }
        }
      }
    }
  }

  /// The Time zone menu. Choosing a city for a widget without a label labels it with the city.
  private func timeZoneRow(_ widget: DesktopWidget) -> some View {
    let model = controller.widgetsSettings
    let id = widget.id
    return SettingsRow(Self.timeZone) {
      SettingsMenuControl(
        key: DesktopWidgetsSettingsModel.key(id, "timeZone"), saved: widget.timeZone,
        options: model.timeZoneOptions(for: widget), waitsForMac: false, policy: .latestWins
      ) { value in
        try await controller.setDesktopWidgetTimeZone(id, value, label: value.map(model.city))
      }
    }
  }

  private func labelRow(_ widget: DesktopWidget) -> some View {
    SettingsRow(Self.label) {
      WidgetTextField(id: widget.id, saved: widget.text, multiline: false)
    }
  }

  /// A position slider in whole percent of the display, 0 at the left or top edge.
  private func percentSlider(
    _ id: String, _ control: String, saved: Double, change: @escaping (Double) -> DesktopWidgetChange
  ) -> some View {
    SettingsSliderControl(
      key: DesktopWidgetsSettingsModel.key(id, control), saved: Int((saved * 100).rounded()), range: 0...100,
      waitsForMac: false, readout: { L("\($0)%") }
    ) { try await controller.changeDesktopWidget(id, change(Double($0) / 100)) }
  }

  // MARK: Words

  static func title(of kind: DesktopWidget.Kind) -> String {
    switch kind {
    case .time: L("Clock")
    case .date: L("Date")
    case .text: L("Text")
    case .countdown: L("Countdown")
    case .greeting: L("Greeting")
    case .battery: L("Battery")
    case .sun: L("Sunrise and sunset")
    case .analog: L("Analog clock")
    case .calendar: L("Month calendar")
    }
  }

  static func symbol(of kind: DesktopWidget.Kind) -> String {
    switch kind {
    case .time: "clock"
    case .date: "calendar"
    case .text: "textformat"
    case .countdown: "hourglass"
    case .greeting: "hand.wave"
    case .battery: "battery.75percent"
    case .sun: "sunrise"
    case .analog: "clock.circle"
    case .calendar: "calendar.day.timeline.left"
    }
  }

  static func title(of style: DesktopWidget.SunStyle) -> String {
    switch style {
    case .next: L("Next sunrise or sunset")
    case .both: L("Today’s sunrise and sunset")
    }
  }

  static func title(of alignment: DesktopWidget.Alignment) -> String {
    switch alignment {
    case .leading: L("Left")
    case .center: L("Center")
    case .trailing: L("Right")
    }
  }

  static func title(of typeface: DesktopWidget.Typeface) -> String {
    switch typeface {
    case .standard: L("Standard")
    case .rounded: L("Rounded")
    case .serif: L("Serif")
    case .monospaced: L("Monospaced")
    }
  }

  static func title(of format: DesktopWidget.TimeFormat) -> String {
    switch format {
    case .system: L("Follow system")
    case .twelveHour: L("12-hour")
    case .twentyFourHour: L("24-hour")
    }
  }
}

/// One widget in the list: what it says now and where, chosen for the editor below by a click.
private struct WidgetListRow: View {
  let widget: DesktopWidget
  let screens: [DesktopWidgetController.Screen]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.widgetsSettings
    let isSelected = model.selectedID == widget.id
    let kind = WidgetsSettingsSection.title(of: widget.kind)
    let place = model.placementTitle(for: widget, among: screens)
    Button {
      model.select(widget.id)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: WidgetsSettingsSection.symbol(of: widget.kind))
          .font(.system(size: 14))
          .foregroundStyle(isSelected ? theme.accent.accent.color : theme.surface.muted.color)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: model.text(for: widget))
            .font(.system(size: 13))
            .lineLimit(1)
          Text(verbatim: widget.isShown ? "\(kind) · \(place)" : "\(kind) · \(place) · \(L("Hidden"))")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.accent.accent.color)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("widgets.list.\(widget.id)")
  }
}

/// The field for a widget's words: a text widget's text, a label, a countdown's event or a name.
/// The desktop follows each keystroke; the field shows what was typed until it is saved.
private struct WidgetTextField: View {
  let id: String
  let saved: String
  let multiline: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let model = controller.widgetsSettings
    let text = Binding(
      get: { model.value(id, "text", saved: saved) },
      set: { model.commit(id, "text", to: String($0.prefix(DesktopWidget.textLimit))) { .text($0) } })
    Group {
      if multiline {
        TextField(noLabel, text: text, axis: .vertical).lineLimit(1...6)
      } else {
        TextField(noLabel, text: text)
      }
    }
    .textFieldStyle(.roundedBorder)
    .font(.system(size: 12.5))
    .frame(maxWidth: 240)
    .settingsRowAccessibility(row)
  }
}

/// A switch for one of a widget's choices, showing what it just sent until the change has run.
private struct WidgetSwitch: View {
  let id: String
  let control: String
  let saved: Bool
  let change: (Bool) -> DesktopWidgetChange

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let model = controller.widgetsSettings
    Toggle(
      isOn: Binding(
        get: { model.value(id, control, saved: saved) },
        set: { model.commit(id, control, to: $0, policy: .dropDuplicates, change) })
    ) {
      Text(verbatim: row?.title ?? "")
    }
    .toggleStyle(.switch)
    .labelsHidden()
    .settingsAccessibilityHint(row?.hint)
    .controlSize(.small)
  }
}

/// The colour well of a widget. The colour panel sends every colour the person passes over, and the
/// desktop follows each one.
private struct WidgetColorControl: View {
  let id: String
  let saved: String

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.widgetsSettings
    ColorPicker(
      selection: Binding(
        get: { Self.color(model.value(id, "color", saved: saved)) },
        set: { color in
          guard let hex = DesktopWidget.hex(NSColor(color)) else { return }
          model.commit(id, "color", to: hex) { .color($0) }
        }),
      supportsOpacity: false
    ) {
      EmptyView()
    }
    .labelsHidden()
  }

  private static func color(_ hex: String) -> Color {
    let rgb = DesktopWidget.rgb(hex) ?? (255, 255, 255)
    return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
  }
}
