import XCTest

@testable import WallpaperMachine

/// The rules of the two Settings controls that take a number: when a typed value is sent and when it
/// is put back, and what a slider sends and when. Both are plain values, so no window is needed.
final class SettingsEntryControlsTests: XCTestCase {
  // MARK: Number field

  func testATypedNumberInRangeIsTheNumberAndAnythingElseIsNot() {
    let range = 1...240
    XCTAssertEqual(SettingsNumberEntry.value(of: "47", in: range), 47)
    XCTAssertEqual(SettingsNumberEntry.value(of: " 60 ", in: range), 60, "Spaces around it do not matter")
    XCTAssertEqual(SettingsNumberEntry.value(of: "1", in: range), 1)
    XCTAssertEqual(SettingsNumberEntry.value(of: "240", in: range), 240)
    for text in ["", "  ", "0", "241", "-3", "4.5", "4,5", "abc", "12 fps", "١٢", "1e2", "+7x"] {
      XCTAssertNil(SettingsNumberEntry.value(of: text, in: range), "\(text.debugDescription) names no number in range")
    }
  }

  func testLeavingTheFieldSendsANewNumberKeepsTheSavedOneAndRestoresInvalidText() {
    let range = 1...240
    XCTAssertEqual(SettingsNumberEntry.outcome(of: "47", in: range, saved: 30), .send(47))
    XCTAssertEqual(SettingsNumberEntry.outcome(of: "30", in: range, saved: 30), .keep, "Nothing to send")
    XCTAssertEqual(SettingsNumberEntry.outcome(of: "999", in: range, saved: 30), .revert, "Out of range goes back to the saved value")
    XCTAssertEqual(SettingsNumberEntry.outcome(of: "", in: range, saved: 30), .revert)
    XCTAssertEqual(SettingsNumberEntry.outcome(of: "x", in: range, saved: 30), .revert)
  }

  /// A live snapshot arrives while the person is typing "47" over a saved 24: the field must not turn
  /// back into 24.
  func testAFocusedFieldShowsWhatIsTypedWhateverTheStoresReport() {
    XCTAssertEqual(SettingsNumberField.displayed(isFocused: true, typed: "47", saved: 24), "47")
    XCTAssertEqual(SettingsNumberField.displayed(isFocused: true, typed: "", saved: 24), "", "Even an emptied field")
    XCTAssertEqual(SettingsNumberField.displayed(isFocused: false, typed: "47", saved: 24), "24", "Unfocused, the stores' value shows")
  }

  // MARK: Slider

  func testADragSendsOnlyWhereItStopsAndNothingWhenItEndsWhereItBegan() {
    var session = SettingsSliderSession(value: 0)
    session.begin(at: 60)
    XCTAssertFalse(session.update(55, from: 60), "A step of a drag is not sent")
    XCTAssertFalse(session.update(40, from: 55))
    XCTAssertEqual(session.value, 40)
    XCTAssertEqual(session.end(), 40, "Letting go sends the value it stopped on")
    XCTAssertFalse(session.isDragging)

    session.begin(at: 60)
    XCTAssertFalse(session.update(70, from: 60))
    XCTAssertFalse(session.update(60, from: 70))
    XCTAssertNil(session.end(), "Back where it began sends nothing")
  }

  func testAChangeWithNoDragIsADecisionSentAtOnce() {
    var session = SettingsSliderSession(value: 0)
    XCTAssertTrue(session.update(61, from: 60), "An arrow key or a VoiceOver adjustment is sent as it is made")
    XCTAssertEqual(session.value, 61)
    XCTAssertFalse(session.update(61, from: 61), "No change is no decision")
    XCTAssertNil(session.end(), "And ending with no drag sends nothing more")
    XCTAssertTrue(session.update(60, from: 61))
  }

  /// The slider showed 50 after an arrow key; the stores later moved to 70; pressing back to 50 is a
  /// change from what is shown now and must be sent although 50 was the last value it held.
  func testAChangeIsComparedWithWhatIsShownNotWithTheLastValueTheSliderHeld() {
    var session = SettingsSliderSession(value: 0)
    XCTAssertTrue(session.update(50, from: 49))
    XCTAssertTrue(session.update(50, from: 51), "From 51 shown, 50 is a new value")
  }

  func testTheFrameRateSliderMapsItsPositionsToCapsAndNoLimit() {
    let slider = FrameRateCapSlider(refreshRate: 120)
    XCTAssertEqual(slider.range, 10...121)
    XCTAssertNil(slider.cap(atPosition: 121), "The top position is no limit")
    XCTAssertEqual(slider.cap(atPosition: 60), 60)
    XCTAssertEqual(slider.position(forCap: nil), 121)
    XCTAssertEqual(slider.position(forCap: 500), 120, "A cap above the refresh shows as the refresh")
    XCTAssertEqual(slider.position(forCap: 3), 10, "and one under ten as ten")
  }

  // MARK: Radio keys

  func testAnArrowMovesToTheNeighbourAndWrapsAtTheEnds() {
    let ids = ["a", "b", "c"]
    XCTAssertEqual(SettingsRadioKeys<String>.neighbour(of: "a", in: ids, delta: 1), "b")
    XCTAssertEqual(SettingsRadioKeys<String>.neighbour(of: "c", in: ids, delta: 1), "a", "Wraps round")
    XCTAssertEqual(SettingsRadioKeys<String>.neighbour(of: "a", in: ids, delta: -1), "c")
    XCTAssertNil(SettingsRadioKeys<String>.neighbour(of: "a", in: ["a"], delta: 1), "A lone choice has no neighbour")
    XCTAssertNil(SettingsRadioKeys<String>.neighbour(of: "z", in: ids, delta: 1))
  }
}
