import Foundation
import XCTest

@testable import WallpaperMachine

/// The unit-test bundle's principal class, which XCTest creates before any test runs.
///
/// The tests run inside the app, so it first takes the desktop away from them: from here on an
/// address opened, a file revealed in Finder, System Settings or a hidden app is only recorded in
/// `DesktopActionLog.shared`. A test that means to check such an action injects its own seam or
/// reads the log; none can open a browser tab or a Finder window on the developer's Mac. The
/// panel's strings follow English (`AppLanguageStore.testHost`), not the language the installed
/// app was last set to, and every test starts in English whatever the test before it bound.
@objc(WallpaperMachineTestBundle)
final class TestBundle: NSObject, XCTestObservation {
  override init() {
    super.init()
    MainActor.assumeIsolated {
      DesktopActions.current = DesktopActionLog.shared.actions
      PanelLocale.shared.bind(to: .testHost)
    }
    XCTestObservationCenter.shared.addTestObserver(self)
  }

  func testCaseWillStart(_ testCase: XCTestCase) {
    MainActor.assumeIsolated { PanelLocale.shared.bind(to: .testHost) }
  }
}

/// What the tests' stand-in desktop was asked to do.
@MainActor
final class DesktopActionLog {
  static let shared = DesktopActionLog()

  private(set) var opened: [URL] = []
  private(set) var revealed: [[URL]] = []
  private(set) var loginItemsOpened = 0
  private(set) var hidden = 0

  var actions: DesktopActions {
    DesktopActions(
      open: { [unowned self] in opened.append($0); return true },
      reveal: { [unowned self] in revealed.append($0) },
      openLoginItemsSettings: { [unowned self] in loginItemsOpened += 1 },
      hideApplication: { [unowned self] in hidden += 1 })
  }
}
