import XCTest

@testable import WallpaperMachine

/// The pure rules of Settings › Displays: what a number field takes, the Custom interval, the time
/// rule's draft, names, the order editor and the lines that summarise a playlist or a rule.
@MainActor
final class DisplaysSettingsDraftsTests: SettingsBTestCase {
  // MARK: Number fields

  func testANumberFieldReadsTheNumbersTheLocaleWritesAndNothingElse() {
    let de = Locale(identifier: "de_DE")
    XCTAssertEqual(DisplaysNumberInput.parse("1.25", locale: english), 1.25)
    XCTAssertEqual(DisplaysNumberInput.parse("1,25", locale: de), 1.25)
    XCTAssertEqual(DisplaysNumberInput.parse(" 30 ", integer: true, locale: english), 30)
    for refused in ["", "  ", "abc", "1.2.3", "12px", "∞"] {
      XCTAssertNil(DisplaysNumberInput.parse(refused, locale: english), refused)
    }
    XCTAssertNil(DisplaysNumberInput.parse("7.5", integer: true, locale: english), "a whole number")
    XCTAssertNil(DisplaysNumberInput.parse("nan", locale: english))
  }

  func testAStoredNumberIsWrittenWithoutGroupingAndWithAFewFractionDigits() {
    XCTAssertEqual(DisplaysNumberInput.text(1.5, digits: 2, locale: english), "1.5")
    XCTAssertEqual(DisplaysNumberInput.text(1, digits: 2, locale: english), "1")
    XCTAssertEqual(DisplaysNumberInput.text(10080, digits: 0, locale: english), "10080")
    XCTAssertEqual(DisplaysNumberInput.text(35.681236, digits: 4, locale: english), "35.6812")
    XCTAssertEqual(DisplaysNumberInput.text(1.5, digits: 2, locale: Locale(identifier: "de_DE")), "1,5")
  }

  /// Return or leaving the field: a number in range is sent once, the stored number is no change,
  /// and anything else is refused, so the text stays to be corrected instead of vanishing.
  func testASubmittedFieldSendsANumberItAcceptsAndRefusesAnythingElseWithoutDroppingIt() {
    let fps = { (text: String?) in
      DisplaysNumberCommit.outcome(
        typed: text, stored: 30, integer: true, locale: self.english, accepts: { (1...60).contains($0) })
    }
    XCTAssertEqual(fps("45"), .send(45))
    XCTAssertEqual(fps(" 30 "), .none, "the stored rate is no change")
    XCTAssertEqual(fps(nil), .none, "nothing typed")
    for refused in ["120", "0", "abc", "", "7.5"] {
      XCTAssertEqual(fps(refused), .refuse, refused.debugDescription)
    }
    let factor = { (text: String) in
      DisplaysNumberCommit.outcome(typed: text, stored: 1, locale: self.english, accepts: { $0 > 0 })
    }
    XCTAssertEqual(factor("1.25"), .send(1.25))
    XCTAssertEqual(factor("0"), .refuse, "a scale factor is greater than 0")
    XCTAssertEqual(factor("-1"), .refuse)
  }

  // MARK: How often

  func testTheIntervalMenuShowsWhatIsSavedUnlessCustomWasChosen() {
    var playlist = DisplayPlaylist()
    playlist.interval = 60
    var draft = DisplaysIntervalDraft()
    XCTAssertEqual(draft.selection(for: playlist), .preset(60))
    playlist.interval = 45
    XCTAssertEqual(draft.selection(for: playlist), .custom, "a stored time the menu does not list")
    playlist.interval = 30
    playlist.trigger = .unlock
    XCTAssertEqual(draft.selection(for: playlist), .unlock)
    draft.customChosen = true
    XCTAssertEqual(draft.selection(for: playlist), .custom, "the draft's Custom wins until a number is saved")
  }

  func testTypedMinutesMustBeAWholeNumberWithinAWeek() {
    XCTAssertEqual(DisplaysIntervalDraft.minutes(from: "45", locale: english), 45)
    XCTAssertEqual(DisplaysIntervalDraft.minutes(from: "10080", locale: english), 10080)
    XCTAssertEqual(DisplaysIntervalDraft.minutes(from: "1", locale: english), 1)
    for refused in ["0", "10081", "7.5", "", "-5", "abc"] {
      XCTAssertNil(DisplaysIntervalDraft.minutes(from: refused, locale: english), refused)
    }
  }

  // MARK: The time rule editor

  private let wallpaper = WallpaperAutomationTarget(kind: .wallpaper, id: "a")

  func testANewRuleStartsEveryDayAtEightWithNoTarget() throws {
    let draft = DisplaysRuleDraft()
    XCTAssertEqual(draft.weekdays, [1, 2, 3, 4, 5, 6, 7])
    XCTAssertEqual(draft.event, .time)
    XCTAssertEqual(draft.time, .eightAM)
    XCTAssertEqual(draft.offsetText, "0")
    XCTAssertNil(draft.id)
    XCTAssertFalse(draft.canSave(locale: english), "a rule needs something to switch to")
    XCTAssertEqual(draft.edit(locale: english), .failure(.noTarget))
  }

  func testATimeRuleDropsAStrayOffsetAndASunRuleKeepsOnlyItsOffset() throws {
    var draft = DisplaysRuleDraft()
    draft.target = wallpaper
    draft.choose(AutomationRuleEdit.weekdaysOnly)
    draft.time = try XCTUnwrap(ClockMinute(minutes: 9 * 60 + 15))
    draft.offsetText = "181"
    var edit = try draft.edit(locale: english).get()
    XCTAssertEqual(edit.weekdays, [2, 3, 4, 5, 6])
    XCTAssertEqual(edit.minute, 555)
    XCTAssertEqual(edit.offset, 0, "the offset of a time rule is not read, however the field was left")
    XCTAssertTrue(draft.canSave(locale: english))

    draft.event = .sunset
    draft.offsetText = "-25"
    edit = try draft.edit(locale: english).get()
    XCTAssertEqual(edit.event, .sunset)
    XCTAssertEqual(edit.offset, -25)
    XCTAssertEqual(edit.minute, ClockMinute.eightAM.minutes, "a sun rule keeps the placeholder time")

    draft.offsetText = "181"
    XCTAssertEqual(draft.edit(locale: english), .failure(.invalidOffset))
    XCTAssertFalse(draft.canSave(locale: english))
    draft.offsetText = "2.5"
    XCTAssertEqual(draft.edit(locale: english), .failure(.invalidOffset), "whole minutes only")
    draft.offsetText = ""
    XCTAssertEqual(draft.edit(locale: english), .failure(.invalidOffset))
    draft.offsetText = "-180"
    XCTAssertNoThrow(try draft.edit(locale: english).get())
  }

  func testARuleWithNoWeekdayIsNotSentAndTheAlertEndsWithTheNextChoiceOfDays() throws {
    var draft = DisplaysRuleDraft()
    draft.target = wallpaper
    draft.weekdays = []
    XCTAssertEqual(draft.edit(locale: english), .failure(.noWeekday))
    draft.showsDaysError = true
    draft.toggle(3)
    XCTAssertEqual(draft.weekdays, [3])
    XCTAssertFalse(draft.showsDaysError, "ticking a day ends the alert")
    draft.toggle(3)
    draft.showsDaysError = true
    draft.toggle(3)
    draft.toggle(3)
    draft.showsDaysError = true
    draft.choose(AutomationRuleEdit.weekends)
    XCTAssertEqual(draft.weekdays, [1, 7])
    XCTAssertFalse(draft.showsDaysError, "a quick set ends it too")
    draft.choose(AutomationRuleEdit.everyDay)
    XCTAssertEqual(draft.weekdays.count, 7)
  }

  func testEditingARuleLoadsItsOwnValues() throws {
    let rule = WallpaperAutomationRule(
      weekdays: [1, 7], event: .sunrise, minute: 480, offset: -20, target: wallpaper)
    let draft = DisplaysRuleDraft(editing: rule)
    XCTAssertEqual(draft.id, rule.id)
    XCTAssertEqual(draft.weekdays, [1, 7])
    XCTAssertEqual(draft.event, .sunrise)
    XCTAssertEqual(draft.offsetText, "-20")
    XCTAssertEqual(draft.target, wallpaper)
    let edit = try draft.edit(locale: english).get()
    XCTAssertEqual(edit, AutomationRuleEdit(editing: rule))
  }

  // MARK: Names

  func testANameIsOneLineOfAtMost128CharactersAndNeedsSomethingBesideSpaces() {
    var form = DisplaysNameForm("  Evening  ")
    XCTAssertEqual(form.trimmed, "Evening")
    XCTAssertTrue(form.canSubmit)
    form.text = "   "
    XCTAssertFalse(form.canSubmit)
    XCTAssertEqual(DisplaysNameForm("two\nlines").text, "two lines")
    XCTAssertEqual(DisplaysNameForm(String(repeating: "x", count: 300)).text.count, 128)
    XCTAssertEqual(DisplaysNameForm.limited("a\r\nb"), "a  b")
  }

  // MARK: The display's own list

  func testTheListDrawsOnlyWhatTheLibraryStillHasAndNumbersThose() {
    let rows = DisplaysPlaylistList.rows(
      of: ["a", "gone", "b", "c"], titles: ["a": "A", "b": "B <img src=x>", "c": "C"])
    XCTAssertEqual(rows.map(\.id), ["a", "b", "c"])
    XCTAssertEqual(rows.map(\.position), [1, 2, 3])
    XCTAssertEqual(rows.map(\.title), ["A", "B <img src=x>", "C"], "a title is text, whatever it looks like")
    XCTAssertEqual(rows.map(\.isFirst), [true, false, false])
    XCTAssertEqual(rows.map(\.isLast), [false, false, true])
    XCTAssertTrue(DisplaysPlaylistList.rows(of: ["gone"], titles: [:]).isEmpty)
  }

  func testADropPutsTheWallpaperWhereItLandedFromEitherSide() {
    let ids = ["a", "b", "c", "d"]
    XCTAssertEqual(DisplaysPlaylistList.dropped(ids, moving: "a", onto: "c"), ["b", "c", "a", "d"], "from above: behind it")
    XCTAssertEqual(DisplaysPlaylistList.dropped(ids, moving: "d", onto: "b"), ["a", "d", "b", "c"], "from below: ahead of it")
    XCTAssertEqual(DisplaysPlaylistList.dropped(ids, moving: "a", onto: "a"), ids)
    XCTAssertEqual(DisplaysPlaylistList.dropped(ids, moving: "x", onto: "a"), ids)
    XCTAssertEqual(DisplaysPlaylistList.dropped(ids, moving: "a", onto: "x"), ids)
    // An id that left the library stays where it was among the neighbours it is not shown with.
    XCTAssertEqual(
      DisplaysPlaylistList.dropped(["a", "gone", "b"], moving: "a", onto: "b"), ["gone", "b", "a"])
  }

  /// After a move the moved row keeps the keyboard on the button that was pressed, unless the row
  /// reached the end that disables it; then on its other move button.
  func testAfterAMoveFocusStaysOnTheButtonPressedUnlessTheRowReachedThatEnd() {
    let order = ["a", "b", "c"]
    XCTAssertEqual(DisplaysPlaylistList.focusAfterMove(of: "b", pressed: .up, in: order), .up)
    XCTAssertEqual(DisplaysPlaylistList.focusAfterMove(of: "a", pressed: .up, in: order), .down, "now first")
    XCTAssertEqual(DisplaysPlaylistList.focusAfterMove(of: "b", pressed: .down, in: order), .down)
    XCTAssertEqual(DisplaysPlaylistList.focusAfterMove(of: "c", pressed: .down, in: order), .up, "now last")
    XCTAssertEqual(DisplaysPlaylistList.focusAfterMove(of: "a", pressed: .up, in: ["a"]), .remove, "nothing else to press")
  }

  // MARK: Saved playlists and rules, in words

  func testASavedPlaylistIsSummarisedByWhatItDoes() {
    func summary(_ edit: (inout DisplayPlaylist) -> Void) -> String {
      var playlist = DisplayPlaylist()
      edit(&playlist)
      return DisplaysPlanSummary.text(
        of: playlist, collectionName: { $0 == "c1" ? "Calm" : nil },
        wallpaperTitle: { $0 == "w1" ? "Aurora" : nil })
    }
    XCTAssertEqual(summary { _ in }, "Off")
    XCTAssertEqual(summary { $0.mode = .rotate }, "All wallpapers, In order, every 30 minutes")
    XCTAssertEqual(
      summary { $0.mode = .rotate; $0.source = .favorites; $0.order = .shuffle; $0.interval = 60 },
      "Favorites, Shuffle, every hour")
    XCTAssertEqual(
      summary { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"]; $0.interval = 1440 },
      "This display’s list (3), In order, every day")
    XCTAssertEqual(
      summary { $0.mode = .rotate; $0.source = .collection; $0.collectionID = "c1"; $0.trigger = .unlock },
      "Collection “Calm”, In order, each time the mac is unlocked")
    XCTAssertEqual(
      summary { $0.mode = .rotate; $0.source = .collection; $0.collectionID = "gone" },
      "A collection that no longer exists, In order, every 30 minutes")
    XCTAssertEqual(
      summary { $0.mode = .dayNight; $0.dayWallpaperID = "w1"; $0.nightWallpaperID = "w2" },
      "Day: Aurora from 07:00; night: a removed wallpaper from 19:00")
    XCTAssertEqual(
      summary { $0.mode = .dayNight },
      "Day: left as it is from 07:00; night: left as it is from 19:00")
  }

  func testARuleIsSummarisedByDaysTimeAndOffset() {
    func rule(_ weekdays: Set<Int>, _ event: WallpaperAutomationRule.Event, minute: Int = 480, offset: Int = 0)
      -> String
    {
      DisplaysRuleSummary.text(
        of: WallpaperAutomationRule(
          weekdays: weekdays, event: event, minute: minute, offset: offset,
          target: WallpaperAutomationTarget(kind: .wallpaper, id: "a")))
    }
    XCTAssertEqual(rule(AutomationRuleEdit.everyDay, .time, minute: 9 * 60 + 5), "Every day · 09:05")
    XCTAssertEqual(rule(AutomationRuleEdit.weekdaysOnly, .time), "Mon, Tue, Wed, Thu, Fri · 08:00")
    XCTAssertEqual(rule([1, 7], .sunrise), "Sun, Sat · Sunrise", "a zero offset is not said")
    XCTAssertEqual(rule([3], .sunset, offset: -25), "Tue · Sunset · 25 min before")
    XCTAssertEqual(rule([3], .sunrise, offset: 10), "Tue · Sunrise · 10 min after")
    XCTAssertEqual(rule([3], .time, minute: 600, offset: 99), "Tue · 10:00", "a time rule has no offset to say")
  }

  // MARK: Times, targets

  func testAClockFieldCarriesEveryMinuteOfTheDayWithoutDriftingAcrossTimeZones() throws {
    for zone in ["America/New_York", "Pacific/Auckland", "UTC"] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
      for minutes in 0..<1440 {
        let date = DisplaysClockField.date(minutes: minutes, calendar: calendar)
        XCTAssertEqual(DisplaysClockField.minutes(of: date, calendar: calendar), minutes, "\(zone) \(minutes)")
      }
    }
  }

  func testATargetMenuStandsForTheKindAndTheIdAndKeepsAnUnresolvedChoice() {
    let targets = AutomationTargets(
      wallpapers: [.init(target: .init(kind: .wallpaper, id: "a"), title: "A")],
      playlists: [.init(target: .init(kind: .playlist, id: "a"), title: "Plan")])
    XCTAssertEqual(DisplaysTargetPicker.identifier(nil), "")
    XCTAssertEqual(DisplaysTargetPicker.identifier(.init(kind: .wallpaper, id: "a")), "wallpaper:a")
    XCTAssertNotEqual(
      DisplaysTargetPicker.identifier(.init(kind: .playlist, id: "a")),
      DisplaysTargetPicker.identifier(.init(kind: .wallpaper, id: "a")), "a wallpaper and a plan may share an id")
    XCTAssertNil(DisplaysTargetPicker.target("", in: targets, keeping: nil))
    XCTAssertEqual(
      DisplaysTargetPicker.target("playlist:a", in: targets, keeping: nil), .init(kind: .playlist, id: "a"))
    let gone = WallpaperAutomationTarget(kind: .wallpaper, id: "gone")
    XCTAssertEqual(
      DisplaysTargetPicker.target("wallpaper:gone", in: targets, keeping: gone), gone,
      "choosing the Unavailable row changes nothing")
    XCTAssertNil(DisplaysTargetPicker.target("wallpaper:gone", in: targets, keeping: nil))
  }
}
