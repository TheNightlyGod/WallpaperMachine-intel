import AppKit
import Foundation
import Observation

/// Page state of Settings › Desktop Widgets that must outlive the page being rebuilt: which widget the
/// editor shows and where a widget being dragged on the preview is before it is let go. It reads
/// the widgets from `controller.desktopWidgets` and acts through the controller's typed actions.
@MainActor
@Observable
final class DesktopWidgetsSettingsModel {
  typealias Screen = DesktopWidgetController.Screen

  /// A widget being dragged on the preview, where the pointer has taken it so far.
  struct Drag: Equatable {
    var id: String
    var x: Double
    var y: Double
  }

  unowned let controller: PanelController
  private var chosenID: String?
  /// The drag in progress on the preview; nil when none is.
  var drag: Drag?
  @ObservationIgnored private let formatters = DesktopWidgetRendering.Formatters()

  init(controller: PanelController) { self.controller = controller }

  var widgets: [DesktopWidget] { controller.desktopWidgets.widgets }

  /// The widget the editor shows: the one chosen, else the first.
  var selected: DesktopWidget? {
    let widgets = widgets
    return widgets.first { $0.id == chosenID } ?? widgets.first
  }

  var selectedID: String? { selected?.id }

  func select(_ id: String?) { chosenID = id }

  /// `widget` where the preview draws it: where a drag has it, or where it was let go while that
  /// position is being saved.
  func shown(_ widget: DesktopWidget) -> DesktopWidget {
    var moved = widget
    if let drag, drag.id == widget.id {
      moved.x = drag.x
      moved.y = drag.y
    } else {
      let position = value(widget.id, "position", saved: [widget.x, widget.y])
      moved.x = position[0]
      moved.y = position[1]
    }
    return moved
  }

  // MARK: Displays

  /// The connected displays, the main one first.
  func screens() -> [Screen] {
    controller.desktopWidgetScreens().sorted { $0.isMain && !$1.isMain }
  }

  /// The display the preview shows for `widget`: its own when it has one and it is connected, else
  /// the main one.
  func previewScreen(for widget: DesktopWidget, among screens: [Screen]) -> Screen? {
    if case .display(let uuid, _) = widget.placement,
      let own = screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
      return own
    }
    return screens.first(where: \.isMain) ?? screens.first
  }

  /// The widgets the preview of `screen` draws, the selected one last so it is on top.
  func widgets(on screen: Screen) -> [DesktopWidget] {
    let selectedID = selectedID
    return widgets
      .filter { $0.isShown && $0.isPlaced(onDisplayUUID: screen.uuid, isMain: screen.isMain) }
      .sorted { ($0.id == selectedID ? 1 : 0) < ($1.id == selectedID ? 1 : 0) }
  }

  /// The Display menu: the main display, every display, each connected one by name, and the
  /// widget's own display when it is not connected.
  func placementOptions(for widget: DesktopWidget, among screens: [Screen]) -> [SettingsMenuOption<DesktopWidget.Placement>] {
    var options: [SettingsMenuOption<DesktopWidget.Placement>] = [
      .init(value: .main, title: L("Main display")),
      .init(value: .all, title: L("All displays")),
    ]
    for screen in screens {
      guard let uuid = screen.uuid else { continue }
      options.append(.init(value: .display(uuid: uuid, name: screen.name), title: screen.name))
    }
    if case .display(let uuid, let name) = widget.placement,
      !screens.contains(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
      options.append(.init(value: widget.placement, title: L("\(name) (not connected)")))
    }
    return options
  }

  /// The menu's value for the widget's display: a display chosen under an earlier name still
  /// selects its entry.
  func placementValue(for widget: DesktopWidget, among screens: [Screen]) -> DesktopWidget.Placement {
    guard case .display(let uuid, _) = widget.placement,
      let screen = screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }),
      let own = screen.uuid
    else { return widget.placement }
    return .display(uuid: own, name: screen.name)
  }

  /// Where the widget is shown, for its line in the list.
  func placementTitle(for widget: DesktopWidget, among screens: [Screen]) -> String {
    let value = placementValue(for: widget, among: screens)
    return placementOptions(for: widget, among: screens).first { $0.value == value }?.title ?? ""
  }

  // MARK: Words

  /// What the widgets are drawn from now: this Mac's clock, language and region, the battery
  /// level the panel last read, and the sunrise and sunset settings.
  func inputs(at date: Date = Date()) -> DesktopWidgetRendering.Inputs {
    .init(
      date: date, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent,
      battery: controller.batteryPercent.map { BatteryReading(percent: $0, isDischarging: true) },
      solar: controller.automations.solar)
  }

  /// What the widget shows at `date`, as the desktop draws it, at `scale` times its size.
  func content(for widget: DesktopWidget, at date: Date = Date(), scale: CGFloat = 1)
    -> DesktopWidgetRendering.Content
  {
    DesktopWidgetRendering.content(for: widget, inputs: inputs(at: date), formatters: formatters, scale: scale)
  }

  /// What the widget says at `date`, on one line: the first line of a text widget, the month of
  /// a calendar, the time a clock face shows.
  func text(for widget: DesktopWidget, at date: Date = Date()) -> String {
    let text = DesktopWidgetRendering.text(for: widget, inputs: inputs(at: date), formatters: formatters)
    return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }

  /// The Date format menu, each style written out for today.
  func dateStyleOptions(for widget: DesktopWidget, at date: Date = Date()) -> [SettingsMenuOption<DesktopWidget.DateStyle>] {
    DesktopWidget.DateStyle.allCases.map { style in
      var sample = widget
      sample.dateStyle = style
      sample.text = ""
      return .init(value: style, title: text(for: sample, at: date))
    }
  }

  /// The Calendar menu: the region's own calendar, then the others by their names in the panel's
  /// language.
  func calendarOptions() -> [SettingsMenuOption<DesktopWidget.CalendarSystem>] {
    let locale = PanelLocale.shared.locale
    return DesktopWidget.CalendarSystem.allCases.map { system in
      guard let identifier = system.identifier else { return .init(value: system, title: L("Follow system")) }
      return .init(value: system, title: locale.localizedString(for: identifier) ?? "\(identifier)")
    }
  }

  /// The time zones the Time zone menu offers: one for each offset people live at, by a city in it.
  static let timeZones = [
    "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Chicago",
    "America/Mexico_City", "America/New_York", "America/Toronto", "America/Bogota", "America/Halifax",
    "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "Atlantic/Reykjavik", "UTC", "Europe/London",
    "Europe/Lisbon", "Africa/Lagos", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
    "Europe/Amsterdam", "Europe/Stockholm", "Europe/Athens", "Africa/Cairo", "Africa/Johannesburg",
    "Europe/Istanbul", "Europe/Moscow", "Africa/Nairobi", "Asia/Tehran", "Asia/Dubai", "Asia/Karachi",
    "Asia/Kolkata", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Ho_Chi_Minh",
    "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Singapore", "Asia/Manila", "Asia/Seoul",
    "Asia/Tokyo", "Australia/Perth", "Australia/Adelaide", "Australia/Brisbane", "Australia/Sydney",
    "Pacific/Auckland",
  ]

  /// The Time zone menu: this Mac's own, then each city by its offset from GMT now, and the
  /// widget's own zone when the list does not have it.
  func timeZoneOptions(for widget: DesktopWidget, at date: Date = Date()) -> [SettingsMenuOption<String?>] {
    var identifiers = Self.timeZones
    if let own = widget.timeZone, !identifiers.contains(own), DesktopWidget.validTimeZone(own) {
      identifiers.append(own)
    }
    let zones = identifiers.compactMap(TimeZone.init(identifier:))
      .sorted { ($0.secondsFromGMT(for: date), city($0.identifier)) < ($1.secondsFromGMT(for: date), city($1.identifier)) }
    return [.init(value: nil, title: L("Follow system"))]
      + zones.map { zone in
        .init(value: zone.identifier, title: "\(city(zone.identifier)) (\(offset(zone, at: date)))")
      }
  }

  /// A time zone's city in the panel's language, such as Tokyo for Asia/Tokyo.
  func city(_ identifier: String) -> String {
    guard identifier != "UTC", let zone = TimeZone(identifier: identifier) else { return identifier }
    let formatter = zoneFormatter
    formatter.locale = PanelLocale.shared.locale
    formatter.timeZone = zone
    formatter.dateFormat = "VVV"
    let name = formatter.string(from: Date())
    return name.isEmpty ? identifier : name
  }

  private func offset(_ zone: TimeZone, at date: Date) -> String {
    let formatter = zoneFormatter
    formatter.locale = PanelLocale.shared.locale
    formatter.timeZone = zone
    formatter.dateFormat = "O"
    return formatter.string(from: date)
  }

  @ObservationIgnored private let zoneFormatter = DateFormatter()

  /// A countdown's day as a date for the date picker: its start in this Mac's time zone, or
  /// today's for an unreadable day.
  func targetDate(_ day: String) -> Date {
    DesktopWidget.start(ofDay: day, in: .autoupdatingCurrent) ?? Calendar.autoupdatingCurrent.startOfDay(for: Date())
  }

  /// The still of the wallpaper on a display, for the preview's background; nil when it shows none.
  func wallpaperStill(on displayID: UInt32) -> PanelImageSource? {
    let row = controller.store.monitorInformationSnapshot.rows.first {
      $0.mirrorTargetDisplayId == nil
        && ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == displayID
    }
    guard let id = row?.wallpaperId, !id.isEmpty else { return nil }
    return controller.libraryRow(id: id)?.still
  }

  /// What the preview asks of a display's wallpaper for its frame. A new wallpaper or new files
  /// make a new request.
  struct FrameRequest: Hashable {
    var displayID: UInt32
    var wallpaperID: String
    var contentRevision: UInt64
  }

  /// What the preview has from a display's wallpaper for the request it answers: a frame or none,
  /// and whether it waits for the wallpaper to play past its intro for a settled one.
  struct WallpaperFrame {
    var request: FrameRequest
    var image: CGImage?
    var waitsToSettle = false
  }

  /// The longest edge, in pixels, of a frame the preview keeps: its widest size on a Retina display.
  static let framePixels = 1024

  /// What each display's wallpaper last gave the preview.
  private(set) var wallpaperFrames: [UInt32: WallpaperFrame] = [:]
  /// Waits before the wallpaper is asked again; tests pass one that does not wait.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  /// The request for the frame of the wallpaper on a display; nil while it shows none.
  func frameRequest(on displayID: UInt32) -> FrameRequest? {
    let rows = controller.store.monitorInformationSnapshot.rows.filter {
      ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == displayID
    }
    let row = rows.first { $0.mirrorTargetDisplayId == nil } ?? rows.first
    guard let id = row?.wallpaperId, !id.isEmpty else { return nil }
    return FrameRequest(
      displayID: displayID, wallpaperID: id, contentRevision: controller.store.wallpaperContentRevision)
  }

  /// What the preview of a display has from the wallpaper it shows now; nil before it answered,
  /// or when its answer was for the wallpaper before.
  private func currentFrame(on displayID: UInt32) -> WallpaperFrame? {
    guard let frame = wallpaperFrames[displayID],
      frame.request.wallpaperID == frameRequest(on: displayID)?.wallpaperID
    else { return nil }
    return frame
  }

  /// The frame the preview of a display draws behind its widgets: one of the wallpaper it shows
  /// now, its first until a settled one comes; nil otherwise, and the still stands in.
  func wallpaperFrame(on displayID: UInt32) -> CGImage? { currentFrame(on: displayID)?.image }

  /// Whether the preview of a display shows the still because its wallpaper has not played long
  /// enough for a frame past its intro or fade-in, and gave no first frame (or a blank one).
  func waitsForWallpaperToSettle(on displayID: UInt32) -> Bool {
    currentFrame(on: displayID).map { $0.image == nil && $0.waitsToSettle } ?? false
  }

  /// Asks the display's wallpaper for a frame: the preview's background is the desktop as it is,
  /// not the author's preview image. A wallpaper still in its intro shows its first frame at once
  /// and is asked again when it can have settled: after the rest of the settle window while it
  /// plays, else when it next starts playing where it can be seen (a wallpaper paused because the
  /// panel covers the desktop does not move on). The caller's task ends with the row, and the wait
  /// with it.
  func loadWallpaperFrame(_ request: FrameRequest) async {
    guard let read = controller.store.wallpaperFrame else { return }
    while !Task.isCancelled {
      let answer = await read(request.displayID, Self.framePixels)
      guard !Task.isCancelled else { return }
      switch answer {
      case .frame(let image):
        wallpaperFrames[request.displayID] = WallpaperFrame(request: request, image: image)
        return
      case .unavailable:
        wallpaperFrames[request.displayID] = WallpaperFrame(request: request, image: nil)
        return
      case .unsettled(let first, let retryAfter):
        // A later first frame replaces an earlier one; none keeps it.
        let shown = wallpaperFrames[request.displayID].flatMap { $0.request == request ? $0.image : nil }
        wallpaperFrames[request.displayID] = WallpaperFrame(
          request: request, image: first ?? shown, waitsToSettle: true)
        if let retryAfter {
          // A moment past the window, so the wallpaper has settled when it is asked.
          do { try await sleep(retryAfter + .milliseconds(250)) } catch { return }
        } else if let change = controller.store.wallpaperSettleChange {
          await change(request.displayID)
        } else {
          return
        }
      }
    }
  }

  // MARK: Editing

  /// The key a widget's control tracks its change under, for its draft and `isBusy`.
  static func key(_ id: String, _ control: String) -> String { "widget.\(id).\(control)" }

  /// Sends the change a control made, showing `value` until it has run. Returns the change's task,
  /// nil when a repeat was dropped.
  @discardableResult
  func commit<Value: Hashable>(
    _ id: String, _ control: String, to value: Value, policy: PanelActionCoordinator.Policy = .latestWins,
    _ change: @escaping (Value) -> DesktopWidgetChange
  ) -> Task<Void, Never>? {
    controller.settings.commit(Self.key(id, control), to: value, policy: policy) { [controller] value in
      try await controller.changeDesktopWidget(id, change(value))
    }
  }

  /// The value a control shows: what it just sent while that is on its way, otherwise `saved`.
  func value<Value: Hashable>(_ id: String, _ control: String, saved: Value) -> Value {
    controller.settings.value(Self.key(id, control), saved: saved)
  }

  /// Ends a drag on the preview where it was let go, and saves that position. The draft shows it
  /// until it is saved, so the widget does not jump back meanwhile.
  @discardableResult
  func endDrag() -> Task<Void, Never>? {
    guard let drag else { return nil }
    self.drag = nil
    return commit(drag.id, "position", to: [drag.x, drag.y]) { .position(x: $0[0], y: $0[1]) }
  }
}
