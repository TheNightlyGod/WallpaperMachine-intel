import AppKit
import XCTest

@testable import WallpaperMachine

@MainActor
final class AppIconCacheTests: XCTestCase {
  func testAnIconFoundOnceIsKeptAndAMissingAppIsLookedUpAgain() {
    var lookups: [String] = []
    var installed: Set<String> = ["com.example.found"]
    let cache = AppIconCache { bundleIdentifier in
      lookups.append(bundleIdentifier)
      return installed.contains(bundleIdentifier) ? NSImage(size: NSSize(width: 1, height: 1)) : nil
    }

    cache.load("com.example.found")
    cache.load("com.example.found")
    XCTAssertNotNil(cache.icon(for: "com.example.found"))
    XCTAssertEqual(lookups, ["com.example.found"], "a found icon is not looked up again")

    cache.load("com.example.missing")
    XCTAssertNil(cache.icon(for: "com.example.missing"))
    installed.insert("com.example.missing")
    cache.load("com.example.missing")
    XCTAssertNotNil(cache.icon(for: "com.example.missing"), "an app installed meanwhile gets its icon")
  }
}
