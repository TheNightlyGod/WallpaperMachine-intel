import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperEditorStateTests: XCTestCase {
    func testClearingOneFieldAndWallpaperPreservesOtherDrafts() {
        let state = WallpaperEditorState()
        let first = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "primary")
        let second = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "secondary")
        let other = WallpaperEditorState.FieldKey(wallpaperID: "forest", fieldID: "primary")
        state.setScalingText("1.25", key: first, locale: Locale(identifier: "en_US"))
        state.setScalingText("unfinished", key: second)
        state.setScalingText("2", key: other)
        state.setPropertyText("unsent", key: first)
        state.clearScaling(first)
        XCTAssertEqual(state.propertyTextDrafts[first], "unsent", "Property and display IDs are separate namespaces")
        XCTAssertEqual(state.scalingDrafts[second]?.text, "unfinished")
        XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        state.discard(wallpaperID: "aurora")
        XCTAssertFalse(state.hasPendingEdits(wallpaperID: "aurora"))
        XCTAssertEqual(state.scalingDrafts[other]?.text, "2")
    }

    func testLocaleParsingAndInvalidInputPreservation() {
        let state = WallpaperEditorState()
        let key = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "primary")
        state.setScalingText("1.25", key: key, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(state.scalingDrafts[key]?.value, 1.25)
        state.setScalingText("1,25", key: key, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(state.scalingDrafts[key]?.value, 1.25)
        for invalid in ["", " ", "0", "-2", "NaN", "Infinity", "1abc"] {
            state.setScalingText(invalid, key: key, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(state.scalingDrafts[key]?.text, invalid)
            XCTAssertNil(state.scalingDrafts[key]?.value)
            XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        }
    }

    func testOnlyRemovedFieldsLoseDraftsDuringReconciliation() {
        let state = WallpaperEditorState()
        let kept = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "kept")
        let changedType = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "changed")
        let other = WallpaperEditorState.FieldKey(wallpaperID: "forest", fieldID: "other")
        state.setPropertyText("editing", key: kept)
        state.setPropertyText("old text", key: changedType)
        state.setPropertyText("other editor", key: other)
        state.setScalingText("unfinished", key: kept)
        state.reconcile(wallpaperID: "aurora", textPropertyIDs: ["kept"])
        XCTAssertEqual(state.scalingDrafts[kept]?.text, "unfinished")
        XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        state.reconcile(wallpaperID: "aurora", displayIDs: [], textPropertyIDs: ["kept"])
        XCTAssertNil(state.scalingDrafts[kept])
        XCTAssertEqual(state.propertyTextDrafts[kept], "editing")
        XCTAssertNil(state.propertyTextDrafts[changedType])
        XCTAssertEqual(state.propertyTextDrafts[other], "other editor")
    }

    func testAValueBeingDraggedIsHeldBesideTheDraftsAndEndsWithItsEdit() {
        let state = WallpaperEditorState()
        let alpha = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "alpha")
        let tint = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "tint")
        let other = WallpaperEditorState.FieldKey(wallpaperID: "forest", fieldID: "alpha")
        state.setPropertyPreview(.number(value: 0.4), key: alpha)
        state.setPropertyPreview(.colorRgb(red: 1, green: 0, blue: 0), key: tint)
        state.setPropertyPreview(.number(value: 0.9), key: other)
        state.setPropertyPreview(.number(value: 0.5), key: alpha)

        XCTAssertEqual(
            state.propertyPreviews(wallpaperID: "aurora"),
            [.init(propertyId: "alpha", value: .number(value: 0.5)), .init(propertyId: "tint", value: .colorRgb(red: 1, green: 0, blue: 0))],
            "the newest step of each property, in a fixed order, for one wallpaper")
        XCTAssertFalse(
            state.hasPendingEdits(wallpaperID: "aurora"),
            "a step is not a draft: it must not make the wallpaper look edited to a preset or an apply")

        XCTAssertTrue(state.clearPropertyPreview(alpha))
        XCTAssertFalse(state.clearPropertyPreview(alpha), "there is nothing left to end")
        XCTAssertEqual(state.propertyPreviews(wallpaperID: "aurora").map(\.propertyId), ["tint"])
        XCTAssertEqual(state.propertyPreviews(wallpaperID: "forest").count, 1)

        state.discard(wallpaperID: "aurora")
        XCTAssertTrue(state.propertyPreviews(wallpaperID: "aurora").isEmpty, "a revert or an apply ends it")
        XCTAssertEqual(state.propertyPreviews(wallpaperID: "forest").count, 1, "for that wallpaper alone")
    }

    func testTheStepsOfEveryWallpaperButTheOpenOneAreDropped() {
        let state = WallpaperEditorState()
        for (wallpaper, property) in [("aurora", "alpha"), ("aurora", "tint"), ("forest", "alpha"), ("marsh", "alpha")] {
            state.setPropertyPreview(.number(value: 1), key: .init(wallpaperID: wallpaper, fieldID: property))
        }

        XCTAssertEqual(state.clearPropertyPreviews(except: "aurora"), ["forest", "marsh"])
        XCTAssertEqual(state.propertyPreviews(wallpaperID: "aurora").count, 2)
        XCTAssertTrue(state.propertyPreviews(wallpaperID: "forest").isEmpty)
        XCTAssertEqual(state.clearPropertyPreviews(except: "aurora"), [], "nothing else to drop")

        XCTAssertTrue(state.clearPropertyPreviews(wallpaperID: "aurora"))
        XCTAssertFalse(state.clearPropertyPreviews(wallpaperID: "aurora"))
    }
}
