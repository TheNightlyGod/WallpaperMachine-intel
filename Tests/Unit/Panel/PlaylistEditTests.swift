import XCTest

@testable import WallpaperMachine

/// The typed values of a playlist edit: the How often menu, clock times, the Wallpapers menu, the
/// order of a list and the time of the next change.
@MainActor
final class PlaylistEditTests: XCTestCase {
  func testTheHowOftenMenuSelectsTheUnlockThenAMenuTimeThenCustom() {
    var playlist = DisplayPlaylist()
    XCTAssertEqual(IntervalChoice.current(for: playlist), .preset(30), "a new playlist rotates every 30 minutes")
    for minutes in IntervalChoice.presets {
      playlist.interval = minutes
      XCTAssertEqual(IntervalChoice.current(for: playlist), .preset(minutes))
    }
    playlist.interval = 45
    XCTAssertEqual(IntervalChoice.current(for: playlist), .custom(45), "a time the menu does not list is Custom")
    playlist.trigger = .unlock
    XCTAssertEqual(IntervalChoice.current(for: playlist), .unlock, "the unlock wins over the stored minutes")
    XCTAssertEqual(IntervalChoice.presets, [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440])
    XCTAssertEqual(IntervalChoice.range, 1...10_080)
  }

  func testOnlyWhatTheMenuAndTheCustomFieldOfferIsOffered() {
    XCTAssertTrue(IntervalChoice.preset(5).isOffered && IntervalChoice.preset(1440).isOffered)
    XCTAssertFalse(IntervalChoice.preset(45).isOffered, "a preset is one of the menu's times")
    XCTAssertTrue(IntervalChoice.custom(1).isOffered && IntervalChoice.custom(10_080).isOffered)
    XCTAssertFalse(IntervalChoice.custom(0).isOffered)
    XCTAssertFalse(IntervalChoice.custom(10_081).isOffered)
    XCTAssertTrue(IntervalChoice.unlock.isOffered)
  }

  func testATimeIsNamedInTheLargestWholeUnitItFillsAndTheUnlockHasItsOwnName() {
    XCTAssertEqual(IntervalChoice.title(minutes: 1), L("Every minute"))
    XCTAssertEqual(IntervalChoice.title(minutes: 60), L("Every hour"))
    XCTAssertEqual(IntervalChoice.title(minutes: 1440), L("Every day"))
    XCTAssertEqual(IntervalChoice.title(minutes: 2880), L("Every \(2) days"))
    XCTAssertEqual(IntervalChoice.title(minutes: 10_080), L("Every \(7) days"))
    XCTAssertEqual(IntervalChoice.title(minutes: 180), L("Every \(3) hours"))
    XCTAssertEqual(IntervalChoice.title(minutes: 45), L("Every \(45) minutes"))
    XCTAssertEqual(IntervalChoice.title(minutes: 5), L("Every \(5) minutes"))
    XCTAssertEqual(IntervalChoice.title(minutes: 90), L("Every \(90) minutes"), "an hour and a half is not whole hours")
    XCTAssertEqual(IntervalChoice.unlock.title, L("Each time the Mac is unlocked"))
    XCTAssertEqual(IntervalChoice.custom(180).title, IntervalChoice.preset(180).title)
  }

  func testAClockTimeIsTwoDigitsOfHoursAndMinutesAndNothingElse() throws {
    XCTAssertEqual(ClockMinute("00:00")?.minutes, 0)
    XCTAssertEqual(ClockMinute("07:05")?.minutes, 425)
    XCTAssertEqual(ClockMinute("23:59")?.minutes, 1439)
    for text in ["24:00", "12:60", "7:05", "07:5", "0705", "07:05:00", "", "ab:cd", "-1:30", "07: 5", "٠٧:٠٥"] {
      XCTAssertNil(ClockMinute(text), text.debugDescription)
    }
    XCTAssertNil(ClockMinute(minutes: -1))
    XCTAssertNil(ClockMinute(minutes: 1440))
    for minutes in [0, 59, 60, 425, 1439] {
      let time = try XCTUnwrap(ClockMinute(minutes: minutes))
      XCTAssertEqual(ClockMinute(time.text), time, "formatting and parsing are inverses")
      XCTAssertEqual(time.hour * 60 + time.minute, minutes)
    }
    XCTAssertEqual(ClockMinute(minutes: 425)?.text, "07:05")
    XCTAssertLessThan(try XCTUnwrap(ClockMinute(minutes: 60)), try XCTUnwrap(ClockMinute(minutes: 61)))
  }

  func testTheWallpapersMenuSelectsTheSourceAndCollectionRowsMakeTheirOwnEdit() {
    var playlist = DisplayPlaylist()
    let exists: (String) -> Bool = { $0 == "night" }
    XCTAssertEqual(PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .all)
    playlist.source = .favorites
    XCTAssertEqual(PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .favorites)
    playlist.source = .list
    XCTAssertEqual(PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .list)
    playlist.source = .collection
    playlist.collectionID = "night"
    XCTAssertEqual(PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .collection(id: "night"))
    playlist.collectionID = "deleted"
    XCTAssertEqual(
      PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .missingCollection,
      "a collection that is gone keeps a row to show")
    playlist.collectionID = nil
    XCTAssertEqual(PlaylistSourceChoice.current(for: playlist, collectionExists: exists), .missingCollection)

    XCTAssertEqual(PlaylistSourceChoice.all.edit, .source(.all))
    XCTAssertEqual(PlaylistSourceChoice.favorites.edit, .source(.favorites))
    XCTAssertEqual(PlaylistSourceChoice.list.edit, .source(.list))
    XCTAssertEqual(PlaylistSourceChoice.collection(id: "night").edit, .collection(id: "night"))
    XCTAssertNil(PlaylistSourceChoice.missingCollection.edit, "choosing the row that stands for a deleted collection changes nothing")
  }

  func testAWallpaperIsPutBeforeOrAfterTheOneItLandedOn() {
    let list = ["a", "b", "c", "d"]
    XCTAssertEqual(PlaylistOrdering.reordered(list, moving: "a", relativeTo: "c", after: true), ["b", "c", "a", "d"])
    XCTAssertEqual(PlaylistOrdering.reordered(list, moving: "a", relativeTo: "c", after: false), ["b", "a", "c", "d"])
    XCTAssertEqual(PlaylistOrdering.reordered(list, moving: "d", relativeTo: "a", after: false), ["d", "a", "b", "c"])
    XCTAssertEqual(PlaylistOrdering.reordered(list, moving: "c", relativeTo: "b", after: true), list, "where it already is")
    XCTAssertEqual(PlaylistOrdering.reordered(list, moving: "a", relativeTo: "nowhere", after: true), list)
  }

  func testAMoveStepsOverTheNeighbourThatIsInstalledAndStopsAtTheEnds() {
    let list = ["a", "gone", "b", "c"]
    let installed: Set<String> = ["a", "b", "c"]
    XCTAssertEqual(PlaylistOrdering.moved("a", by: 1, in: list, installed: installed), ["gone", "b", "a", "c"])
    XCTAssertEqual(PlaylistOrdering.moved("b", by: -1, in: list, installed: installed), ["b", "a", "gone", "c"])
    XCTAssertNil(PlaylistOrdering.moved("a", by: -1, in: list, installed: installed), "first of the installed ones")
    XCTAssertNil(PlaylistOrdering.moved("c", by: 1, in: list, installed: installed), "last of the installed ones")
    XCTAssertNil(PlaylistOrdering.moved("gone", by: 1, in: list, installed: installed), "a wallpaper that left has no row to move")
    XCTAssertNil(PlaylistOrdering.moved("a", by: 2, in: list, installed: installed))
    XCTAssertNil(PlaylistOrdering.moved("a", by: 0, in: list, installed: installed))
  }

  func testTheNextChangeIsTheTimeAloneTodayAndTheWeekdayWithTheTimeOtherwise() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let locale = Locale(identifier: "en_US")
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9, minute: 30)))
    let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 5)))
    let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 5)))

    let sameDay = PlaylistState.changeTime(today, now: now, locale: locale, calendar: calendar)
    XCTAssertTrue(sameDay.contains("3:05"), sameDay)
    XCTAssertFalse(sameDay.contains("Thu"), "no weekday for a change that falls today")
    let later = PlaylistState.changeTime(tomorrow, now: now, locale: locale, calendar: calendar)
    XCTAssertTrue(later.contains("Thu") && later.contains("3:05"), later)

    let japanese = PlaylistState.changeTime(
      tomorrow, now: now, locale: Locale(identifier: "ja_JP"), calendar: calendar)
    XCTAssertTrue(japanese.contains("木"), "the weekday follows the panel's language: \(japanese)")
  }

  func testAnUndatedChangeHasNoText() {
    let state = PlaylistState(
      display: "primary", playlist: DisplayPlaylist(), nextChange: nil, isHeld: false, skipped: [], listedCount: 0,
      source: .all)
    XCTAssertNil(state.nextChangeText(locale: Locale(identifier: "en_US")))
  }

  func testAnAutomaticRuleStoresTheValueItsKindIgnoresAsAFixedOne() throws {
    let target = WallpaperAutomationTarget(kind: .wallpaper, id: "a")
    let time = AutomationRuleEdit(time: try XCTUnwrap(ClockMinute(minutes: 630)), offset: 181, target: target)
    XCTAssertEqual(time.minute, 630)
    XCTAssertEqual(time.offset, 0, "a stray offset of an edited sun rule is dropped when it becomes a time rule")
    let sunset = AutomationRuleEdit(event: .sunset, time: try XCTUnwrap(ClockMinute(minutes: 630)), offset: -25, target: target)
    XCTAssertEqual(sunset.minute, 480, "a sun rule keeps the placeholder time")
    XCTAssertEqual(sunset.offset, -25)
    XCTAssertEqual(AutomationRuleEdit(target: target).weekdays, AutomationRuleEdit.everyDay)
    XCTAssertEqual(AutomationRuleEdit.weekdaysOnly, [2, 3, 4, 5, 6])
    XCTAssertEqual(AutomationRuleEdit.weekends, [1, 7])
    let saved = WallpaperAutomationRule(weekdays: [2], event: .sunrise, minute: 480, offset: 15, target: target)
    let edit = AutomationRuleEdit(editing: saved)
    XCTAssertEqual(edit.id, saved.id)
    XCTAssertEqual(edit.time, ClockMinute(minutes: 480))
    XCTAssertEqual(edit.offset, 15)
  }
}
