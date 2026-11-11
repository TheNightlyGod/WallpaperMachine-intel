import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Settings › Desktop Widgets: adding, editing, arranging and removing the desktop's clocks and dates. The
/// page edits the panel's own store over the fixture's preferences, so nothing reaches the desktop.
@MainActor
final class WidgetsSettingsTests: PanelTestCase {
  typealias Screen = DesktopWidgetController.Screen

  private let laptop = Screen(
    displayID: 1, uuid: "AAAA-1", name: "Built-in Display",
    frame: NSRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
  private let external = Screen(
    displayID: 2, uuid: "BBBB-2", name: "Studio Display",
    frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), isMain: false)

  func testAddingOpensTheNewWidgetAndRemovingMovesToTheNextOne() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.widgetsSettings
      XCTAssertNil(model.selected)

      try await controller.addDesktopWidget(.time)
      try await controller.addDesktopWidget(.date)
      try await controller.addDesktopWidget(.time)
      let ids = model.widgets.map(\.id)
      XCTAssertEqual(model.widgets.map(\.kind), [.time, .date, .time])
      XCTAssertEqual(model.selectedID, ids[2], "a new widget opens in the editor")

      model.select(ids[1])
      try await controller.removeDesktopWidget(ids[1])
      XCTAssertEqual(model.selectedID, ids[2], "the one after it")
      try await controller.removeDesktopWidget(ids[2])
      XCTAssertEqual(model.selectedID, ids[0], "the one before the last")

      XCTAssertEqual(
        DesktopWidgetStore(defaults: panel.defaults).widgets.map(\.id), [ids[0]], "every change is kept")
    }
  }

  func testTheControlsChangeAWidgetWithoutWaitingForTheRenderer() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertTrue(controller.settings.isUnavailable, "no renderer snapshot yet")
      try await controller.addDesktopWidget(.time)
      let model = controller.widgetsSettings
      let id = try XCTUnwrap(model.selectedID)

      await model.commit(id, "size", to: 140) { .size($0) }?.value
      await model.commit(id, "color", to: "#FF8000") { .color($0) }?.value
      await model.commit(id, "seconds", to: true, policy: .dropDuplicates) { .showsSeconds($0) }?.value
      model.drag = .init(id: id, x: 0.1, y: 0.9)
      XCTAssertEqual(model.shown(try XCTUnwrap(model.selected)).x, 0.1, "the preview follows the drag")
      await model.endDrag()?.value
      XCTAssertNil(model.drag)

      let widget = try XCTUnwrap(model.selected)
      XCTAssertEqual(widget.size, 140)
      XCTAssertEqual(widget.color, "#FF8000")
      XCTAssertTrue(widget.showsSeconds)
      XCTAssertEqual(widget.x, 0.1)
      XCTAssertEqual(widget.y, 0.9)
    }
  }

  func testTheEditorsRowsAreOfferedOnlyForAWidgetOfTheirKind() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let editor = Set(WidgetsSettingsSection.editorItems.map(\.id))
      XCTAssertEqual(WidgetsSettingsSection.unofferedItems(controller), editor, "nothing to edit yet")
      XCTAssertFalse(SettingsRegistry.unofferedItems(controller).contains(WidgetsSettingsSection.add.id))

      typealias Section = WidgetsSettingsSection
      let kindRows = Set(Section.kindRows.keys)
      let expected: [DesktopWidget.Kind: Set<String>] = [
        .time: [Section.typeface.id, Section.timeFormat.id, Section.seconds.id, Section.timeZone.id, Section.label.id],
        .date: [Section.typeface.id, Section.dateFormat.id, Section.calendarSystem.id, Section.timeZone.id, Section.label.id],
        .text: [Section.typeface.id, Section.content.id],
        .countdown: [Section.typeface.id, Section.event.id, Section.targetDay.id],
        .greeting: [Section.typeface.id, Section.name.id],
        .battery: [Section.typeface.id],
        .sun: [Section.typeface.id, Section.sunStyle.id, Section.timeFormat.id],
        .analog: [Section.seconds.id, Section.timeZone.id],
        .calendar: [Section.typeface.id],
      ]
      for kind in DesktopWidget.Kind.allCases {
        try await controller.addDesktopWidget(kind)
        XCTAssertEqual(
          WidgetsSettingsSection.unofferedItems(controller), kindRows.subtracting(expected[kind] ?? []), "\(kind)")
        let widget = try XCTUnwrap(controller.widgetsSettings.selected)
        XCTAssertFalse(controller.widgetsSettings.text(for: widget).isEmpty, "\(kind) says something in the list")
      }
    }
  }

  func testTheTimeZoneMenuOffersCitiesAndLabelsAClockWithTheCityChosen() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.addDesktopWidget(.time)
      let model = controller.widgetsSettings
      let id = try XCTUnwrap(model.selectedID)
      var widget = try XCTUnwrap(model.selected)
      let options = model.timeZoneOptions(for: widget)
      XCTAssertNil(options.first?.value, "this Mac's own first")
      XCTAssertTrue(options.contains { $0.value == "Asia/Tokyo" })
      XCTAssertEqual(Set(options.map(\.title)).count, options.count, "each city reads differently")

      try await controller.setDesktopWidgetTimeZone(id, "Asia/Tokyo", label: model.city("Asia/Tokyo"))
      XCTAssertEqual(model.selected?.text, model.city("Asia/Tokyo"), "a world clock says whose time it is")
      try await controller.changeDesktopWidget(id, .text("Home"))
      try await controller.setDesktopWidgetTimeZone(id, "America/Argentina/Ushuaia", label: "Ushuaia")
      widget = try XCTUnwrap(model.selected)
      XCTAssertEqual(widget.text, "Home", "a label of one's own stays")
      XCTAssertEqual(widget.timeZone, "America/Argentina/Ushuaia")
      XCTAssertEqual(
        model.timeZoneOptions(for: widget).filter { $0.value == "America/Argentina/Ushuaia" }.count, 1,
        "a zone the list lacks is still offered")
      XCTAssertEqual(
        model.calendarOptions().map(\.value), DesktopWidget.CalendarSystem.allCases, "every calendar by name")
      XCTAssertEqual(Set(model.calendarOptions().map(\.title)).count, DesktopWidget.CalendarSystem.allCases.count)
    }
  }

  /// The preview's background is a settled frame of the display's wallpaper, shown only while that
  /// wallpaper is still the one shown; otherwise the still stands in.
  func testThePreviewShowsTheFrameTheDisplaysWallpaperDrew() async throws {
    try await withPanel { panel in
      let model = panel.controller.widgetsSettings
      Self.show("aurora", in: panel)
      let drawn = try Self.picture()
      var asked: [(UInt32, Int)] = []
      panel.store.wallpaperFrame = { display, pixels in
        asked.append((display, pixels))
        return .frame(drawn)
      }

      XCTAssertNil(model.frameRequest(on: 2), "a display without a wallpaper asks nothing")
      let request = try XCTUnwrap(model.frameRequest(on: 1))
      XCTAssertNil(model.wallpaperFrame(on: 1), "the still until the frame comes")
      await model.loadWallpaperFrame(request)
      XCTAssertTrue(model.wallpaperFrame(on: 1) === drawn)
      XCTAssertFalse(model.waitsForWallpaperToSettle(on: 1))
      XCTAssertEqual(asked.map(\.0), [1])
      XCTAssertEqual(asked.map(\.1), [DesktopWidgetsSettingsModel.framePixels])

      Self.show("rain", in: panel)
      XCTAssertNil(model.wallpaperFrame(on: 1), "a frame of the wallpaper before is not shown")
      XCTAssertNotEqual(model.frameRequest(on: 1), request, "the new wallpaper is asked again")
    }
  }

  /// A wallpaper still in its intro shows its first frame at once and is asked once more when it
  /// can have settled, whose frame then replaces it; without a first frame the still shows with a
  /// note under it. One that does not play is asked again once it plays.
  func testAWallpaperInItsIntroShowsItsFirstFrameThenItsSettledOne() async throws {
    try await withPanel { panel in
      let model = panel.controller.widgetsSettings
      Self.show("aurora", in: panel)
      let first = try Self.picture(), settled = try Self.picture()
      var answers: [DesktopWallpaperFrames.Answer] = [
        .unsettled(first: first, retryAfter: .seconds(9)), .frame(settled),
      ]
      panel.store.wallpaperFrame = { _, _ in answers.removeFirst() }
      var waits: [Duration] = []
      var shownWhileWaiting: CGImage?
      var notedWhileWaiting = true
      model.sleep = { duration in
        await MainActor.run {
          waits.append(duration)
          shownWhileWaiting = model.wallpaperFrame(on: 1)
          notedWhileWaiting = model.waitsForWallpaperToSettle(on: 1)
        }
      }

      await model.loadWallpaperFrame(try XCTUnwrap(model.frameRequest(on: 1)))
      XCTAssertTrue(shownWhileWaiting === first, "the first frame at once")
      XCTAssertFalse(notedWhileWaiting, "no note over a frame")
      XCTAssertEqual(waits.count, 1)
      XCTAssertGreaterThanOrEqual(waits.first ?? .zero, .seconds(9))
      XCTAssertTrue(model.wallpaperFrame(on: 1) === settled, "then the settled one")

      answers = [.unsettled(first: nil, retryAfter: nil)]
      waits = []
      Self.show("rain", in: panel)
      await model.loadWallpaperFrame(try XCTUnwrap(model.frameRequest(on: 1)))
      XCTAssertNil(model.wallpaperFrame(on: 1))
      XCTAssertTrue(model.waitsForWallpaperToSettle(on: 1), "the still, with its note")
      XCTAssertEqual(waits, [], "a wallpaper that does not play is not waited for")

      // Paused because the panel covers the desktop: asked again once it has played.
      answers = [.unsettled(first: nil, retryAfter: nil), .frame(settled)]
      var changes = 0
      panel.store.wallpaperSettleChange = { display in
        XCTAssertEqual(display, 1)
        changes += 1
      }
      Self.show("snow", in: panel)
      await model.loadWallpaperFrame(try XCTUnwrap(model.frameRequest(on: 1)))
      XCTAssertEqual(changes, 1)
      XCTAssertTrue(model.wallpaperFrame(on: 1) === settled)
    }
  }

  private static func show(_ wallpaper: String, in panel: PanelFixture) {
    panel.store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
      BridgeMonitorInfoRow(
        displayId: "1", title: "Built-in Display (1 - Primary)", wallpaperId: wallpaper,
        wallpaperTitle: wallpaper, mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
        scalingMode: "fill", targetFps: "30", audioResponse: false)
    ])
  }

  private static func picture() throws -> CGImage {
    try XCTUnwrap(
      CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
        .makeImage())
  }

  func testTheDisplayMenuOffersEveryDisplayAndKeepsOneThatIsNotConnected() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let both = [external, laptop]
      controller.desktopWidgetScreens = { both }
      try await controller.addDesktopWidget(.time)
      let model = controller.widgetsSettings
      let id = try XCTUnwrap(model.selectedID)
      let screens = model.screens()
      XCTAssertEqual(screens.map(\.displayID), [1, 2], "the main display first")

      var widget = try XCTUnwrap(model.selected)
      XCTAssertEqual(
        model.placementOptions(for: widget, among: screens).map(\.title),
        ["Main display", "All displays", "Built-in Display", "Studio Display"])
      XCTAssertEqual(model.previewScreen(for: widget, among: screens)?.displayID, 1)

      try await controller.changeDesktopWidget(id, .placement(.display(uuid: "bbbb-2", name: "Old name")))
      widget = try XCTUnwrap(model.selected)
      XCTAssertEqual(
        model.placementValue(for: widget, among: screens), .display(uuid: "BBBB-2", name: "Studio Display"),
        "a display chosen under another name still selects its entry")
      XCTAssertEqual(model.placementTitle(for: widget, among: screens), "Studio Display")
      XCTAssertEqual(model.previewScreen(for: widget, among: screens)?.displayID, 2)

      let one = [laptop]
      controller.desktopWidgetScreens = { one }
      let options = model.placementOptions(for: widget, among: model.screens())
      XCTAssertEqual(options.last?.title, "Old name (not connected)")
      XCTAssertEqual(options.last?.value, widget.placement)
      XCTAssertEqual(model.widgets(on: laptop).count, 0, "it is not drawn on another display")
    }
  }

  func testTheDateFormatMenuWritesEveryStyleOut() async throws {
    try await withPanel { panel in
      try await panel.controller.addDesktopWidget(.date)
      let model = panel.controller.widgetsSettings
      try await panel.controller.changeDesktopWidget(try XCTUnwrap(model.selectedID), .text("Paris"))
      let widget = try XCTUnwrap(model.selected)
      let titles = model.dateStyleOptions(for: widget).map(\.title)
      XCTAssertFalse(titles.contains { $0.hasPrefix("Paris") }, "the menu shows the style, not the label")
      XCTAssertEqual(titles.count, DesktopWidget.DateStyle.allCases.count)
      XCTAssertEqual(Set(titles).count, titles.count, "each style reads differently")
      XCTAssertFalse(titles.contains(""))
    }
  }

  func testASearchFindsTheWidgetsPageByWhatItAdds() async throws {
    try await withPanel { panel in
      let settings = panel.controller.settings
      settings.query = "Clock"
      XCTAssertTrue(settings.search.shows(WidgetsSettingsSection.add))
      settings.query = "Countdown"
      XCTAssertTrue(settings.search.shows(WidgetsSettingsSection.add), "by every kind it adds")
      XCTAssertFalse(settings.search.shows(WidgetsSettingsSection.size), "no widget, no editor")
      settings.query = ""
    }
  }

  // MARK: Layout

  private func settle(_ hosting: NSHostingController<AnyView>, _ window: NSWindow, at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    hosting.view.layoutSubtreeIfNeeded()
  }

  func testThePageLaysOutInTheNarrowestAndTheWidestColumnWithAndWithoutWidgets() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let both = [external, laptop]
      controller.desktopWidgetScreens = { both }
      let hosting = NSHostingController(
        rootView: AnyView(
          SettingsPages().environment(controller)
            .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      defer {
        window.contentViewController = nil
        window.close()
        PanelLocale.shared.bind(to: .testHost)
      }
      controller.settings.select(.widgets)
      for widgets in [false, true] {
        if widgets {
          try await controller.addDesktopWidget(.date)
          try await controller.addDesktopWidget(.time)
          try await controller.addDesktopWidget(.calendar)
          try await controller.addDesktopWidget(.analog)
          try await controller.addDesktopWidget(.countdown)
        }
        for language in ["en", "ja"] {
          PanelLocale.shared.bind(
            to: AppLanguageStore(defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: [language]))
          for size in [NSSize(width: 460, height: 560), NSSize(width: 980, height: 800)] {
            settle(hosting, window, at: size)
            let context = "\(widgets ? "widgets" : "empty") \(language) \(Int(size.width))"
            let least = hosting.sizeThatFits(in: NSSize(width: 0, height: size.height))
            XCTAssertLessThanOrEqual(least.width, size.width, "\(context): too wide")
            let taken = hosting.sizeThatFits(in: size)
            XCTAssertEqual(taken.width, size.width, accuracy: 1, "\(context): takes the width it is given")
          }
        }
      }
      XCTAssertFalse(window.isVisible, "layout stays off screen")
    }
  }
}
