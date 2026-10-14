import XCTest

@testable import WallpaperMachine

/// Whether the desktop follows a wallpaper's pending property edits. The choice belongs to this
/// Mac and starts off, so what is checked here is that nothing but an explicit "on" turns it on,
/// that either explicit value sticks, and that it never travels in a backup.
@MainActor
final class LivePropertyEditingTests: XCTestCase {
  func testItIsOffUntilTheUserTurnsItOnAndEitherChoiceSticks() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let center = NotificationCenter()
    var posts = 0
    let observer = center.addObserver(forName: LivePropertyEditing.didChange, object: nil, queue: nil) { _ in
      posts += 1
    }
    defer { center.removeObserver(observer) }

    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: defaults), "an untouched Mac does not show edits on the desktop")
    LivePropertyEditing.setEnabled(true, defaults: defaults, center: center)
    XCTAssertTrue(LivePropertyEditing.isEnabled(defaults: defaults))
    XCTAssertEqual(posts, 1)
    LivePropertyEditing.setEnabled(false, defaults: defaults, center: center)
    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: defaults), "an explicit off beats whatever the build default becomes")
    XCTAssertEqual(posts, 2, "whoever follows the choice is told about each write")
    XCTAssertEqual(
      defaults.object(forKey: LivePropertyEditing.defaultsKey) as? Bool, false,
      "off is stored, not forgotten, so a later change of the default leaves this choice alone")
  }

  func testTheChoiceIsKeptPerPreferenceDomain() throws {
    let first = try TemporaryDefaults.make(for: self).defaults
    let second = try TemporaryDefaults.make(for: self).defaults
    let center = NotificationCenter()
    LivePropertyEditing.setEnabled(true, defaults: first, center: center)
    LivePropertyEditing.setEnabled(false, defaults: second, center: center)
    XCTAssertTrue(LivePropertyEditing.isEnabled(defaults: first))
    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: second))
  }

  /// A choice about how this Mac shows edits is not part of a wallpaper library, so a restore on
  /// another Mac must not switch it.
  func testTheChoiceDoesNotTravelInABackup() throws {
    let (defaults, suite) = try TemporaryDefaults.make(for: self)
    LivePropertyEditing.setEnabled(true, defaults: defaults, center: NotificationCenter())
    defaults.set(true, forKey: "WallpaperMachine.hideAfterActivating")

    let preferences = try WallpaperBackupPreferences(defaults: defaults, domainName: suite)
    XCTAssertNotNil(
      preferences.values["WallpaperMachine.hideAfterActivating"],
      "the capture reads this suite, so the missing key below is meaningful")
    XCTAssertNil(preferences.values[LivePropertyEditing.defaultsKey])
  }
}
