import SwiftUI
import XCTest
@testable import WallpaperMachine

/// The update window's notes translation: it opens on the language it is given and the switch
/// above the notes changes only what this window shows.
@MainActor
final class UpdateWindowTests: XCTestCase {
    func testSwitchAboveTheNotesChangesTheTranslation() async throws {
        let store = AppUpdateStore(
            currentVersion: "1.0.0", client: DisabledAppUpdateClient(),
            defaults: try TemporaryDefaults.make(for: self).defaults)
        let notesLanguage = UpdateNotesLanguage(.korean)
        let hosting = NSHostingController(
            rootView: UpdateWindowView(
                store: store, actions: .init(skip: {}, later: {}, install: {}, setMode: { _ in }),
                notesLanguage: notesLanguage))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UpdateWindow.defaultContentSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        let control = try XCTUnwrap(Self.segmentedControl(in: hosting.view))
        XCTAssertEqual(control.segmentCount, AppReleaseHistory.Language.allCases.count)
        XCTAssertEqual(control.selectedSegment, AppReleaseHistory.Language.korean.rawValue)
        for language in [AppReleaseHistory.Language.chinese, .english] {
            control.selectedSegment = language.rawValue
            control.sendAction(control.action, to: control.target)
            XCTAssertEqual(notesLanguage.selection, language)
        }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "the title bar holds only the window buttons")
    }

    private static func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for child in view.subviews {
            if let found = segmentedControl(in: child) { return found }
        }
        return nil
    }
}
