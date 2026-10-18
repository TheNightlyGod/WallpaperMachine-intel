import XCTest

@testable import WallpaperMachine

final class AppPermissionLocalizationTests: XCTestCase {
  func testPermissionExplanationsArePackagedForEveryShippedLanguage() throws {
    let keys = [
      "NSAppleEventsUsageDescription", "NSAudioCaptureUsageDescription", "NSLocationUsageDescription",
    ]
    let missing = "__missing_permission_explanation__"
    for language in AppLanguage.supported {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language.tag, ofType: "lproj"))
      let resources = try XCTUnwrap(Bundle(path: path))
      for key in keys {
        let english = try XCTUnwrap(Bundle.main.infoDictionary?[key] as? String)
        let translated = resources.localizedString(forKey: key, value: missing, table: "InfoPlist")
        XCTAssertNotEqual(translated, missing, "\(language.tag): \(key) is not packaged")
        XCTAssertFalse(translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if language.tag == "en" {
          XCTAssertEqual(translated, english, "The fallback and English permission explanation differ")
        } else {
          XCTAssertNotEqual(translated, english, "\(language.tag): \(key) falls back to English")
        }
      }
    }
  }
}
