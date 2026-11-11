import Foundation

/// One change a Settings › Desktop Widgets control makes to a widget.
enum DesktopWidgetChange: Hashable, Sendable {
  case shown(Bool)
  case placement(DesktopWidget.Placement)
  case size(Int)
  case position(x: Double, y: Double)
  case x(Double)
  case y(Double)
  case alignment(DesktopWidget.Alignment)
  case typeface(DesktopWidget.Typeface)
  case weight(Int)
  case color(String)
  case opacity(Int)
  case shadow(Bool)
  case timeFormat(DesktopWidget.TimeFormat)
  case showsSeconds(Bool)
  case dateStyle(DesktopWidget.DateStyle)
  case calendarSystem(DesktopWidget.CalendarSystem)
  case text(String)
  case targetDay(String)
  case sunStyle(DesktopWidget.SunStyle)

  func apply(to widget: inout DesktopWidget) {
    switch self {
    case .shown(let value): widget.isShown = value
    case .placement(let value): widget.placement = value
    case .size(let value): widget.size = value
    case .position(let x, let y):
      widget.x = x
      widget.y = y
    case .x(let value): widget.x = value
    case .y(let value): widget.y = value
    case .alignment(let value): widget.alignment = value
    case .typeface(let value): widget.typeface = value
    case .weight(let value): widget.weight = value
    case .color(let value): widget.color = value
    case .opacity(let value): widget.opacity = value
    case .shadow(let value): widget.hasShadow = value
    case .timeFormat(let value): widget.timeFormat = value
    case .showsSeconds(let value): widget.showsSeconds = value
    case .dateStyle(let value): widget.dateStyle = value
    case .calendarSystem(let value): widget.calendarSystem = value
    case .text(let value): widget.text = value
    case .targetDay(let value): widget.targetDay = value
    case .sunStyle(let value): widget.sunStyle = value
    }
  }
}

/// Settings › Desktop Widgets' actions. A widget belongs to no wallpaper and the renderer never draws it,
/// so none of them waits for a wallpaper command or clears an older banner.
extension PanelController {
  /// Adds a widget of `kind` on the main display and opens it in the editor.
  func addDesktopWidget(_ kind: DesktopWidget.Kind) async throws {
    _ = try await run(.immediate) {
      let widget = try desktopWidgets.add(kind)
      widgetsSettings.select(widget.id)
    }
  }

  func changeDesktopWidget(_ id: String, _ change: DesktopWidgetChange) async throws {
    _ = try await run(.immediate) {
      try desktopWidgets.update(id) { change.apply(to: &$0) }
    }
  }

  /// Moves a clock or a date to another time zone (nil for this Mac's own). A clock or a date
  /// without a label takes `label`, the city's name, so a world clock says whose time it tells.
  func setDesktopWidgetTimeZone(_ id: String, _ zone: String?, label: String?) async throws {
    _ = try await run(.immediate) {
      try desktopWidgets.update(id) { widget in
        widget.timeZone = zone
        if zone != nil, let label, widget.text.isEmpty, [.time, .date].contains(widget.kind) {
          widget.text = label
        }
      }
    }
  }

  /// Removes a widget; the editor moves to the one listed after it, or before it when it was last.
  func removeDesktopWidget(_ id: String) async throws {
    _ = try await run(.immediate) {
      let ids = desktopWidgets.widgets.map(\.id)
      let wasSelected = widgetsSettings.selectedID == id
      try desktopWidgets.remove(id)
      if wasSelected, let index = ids.firstIndex(of: id) {
        let remaining = ids.filter { $0 != id }
        widgetsSettings.select(remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)])
      }
    }
  }
}
