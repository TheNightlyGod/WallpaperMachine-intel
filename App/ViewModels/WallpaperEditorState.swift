import Foundation
import Observation

@MainActor
@Observable
final class WallpaperEditorState {
    struct FieldKey: Hashable {
        let wallpaperID: String
        let fieldID: String
    }

    struct ScalingDraft {
        let text: String
        let value: Double?
        let errorMessage: String?
    }

    private(set) var scalingDrafts: [FieldKey: ScalingDraft] = [:]
    private(set) var propertyTextDrafts: [FieldKey: String] = [:]
    /// The value a slider or colour is being dragged to. Shown on the previews, never kept as an
    /// edit, so it is not a draft: it does not make the wallpaper dirty or block a preset, and the
    /// edit that ends the drag, a revert, an apply or a switch to another wallpaper drops it.
    @ObservationIgnored private(set) var propertyPreviewValues: [FieldKey: BridgePropertyValue] = [:]
    /// A Wallpaper Engine option of one wallpaper.
    struct EngineFieldKey: Hashable {
        let wallpaperID: String
        let option: BridgeEngineOptionId
    }
    /// The value a Wallpaper Engine option's slider is being dragged to, held like
    /// `propertyPreviewValues`: shown, never an edit.
    @ObservationIgnored private(set) var engineOptionPreviewValues: [EngineFieldKey: BridgePropertyValue] = [:]
    var expandedSections: [FieldKey: Bool] = [:]

    static func scalingFormat(locale: Locale = .current) -> FloatingPointFormatStyle<Double> {
        .number.locale(locale).grouping(.never).precision(.fractionLength(0...8))
    }

    func setScalingText(_ text: String, key: FieldKey, locale: Locale = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Foundation's parse strategy accepts numeric prefixes (for example "1abc").
        // Check the complete decimal token before using the matching locale parser.
        let decimal = locale.decimalSeparator?.first ?? "."
        var sawDecimal = false
        var sawDigit = false
        var validToken = true
        for (index, character) in trimmed.enumerated() {
            if index == 0 && (character == "+" || character == "-") { continue }
            if character == decimal && !sawDecimal {
                sawDecimal = true
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                sawDigit = true
            } else {
                validToken = false
                break
            }
        }
        let strategy = FloatingPointParseStrategy(format: Self.scalingFormat(locale: locale), lenient: false)
        let value = try? strategy.parse(trimmed)
        if let value, value.isFinite, value > 0, validToken, sawDigit {
            scalingDrafts[key] = ScalingDraft(text: text, value: value, errorMessage: nil)
        } else {
            scalingDrafts[key] = ScalingDraft(text: text, value: nil,
                errorMessage: String(localized: "Enter a finite scaling factor greater than zero."))
        }
    }

    func setPropertyText(_ text: String, key: FieldKey) { propertyTextDrafts[key] = text }
    func clearScaling(_ key: FieldKey) { scalingDrafts.removeValue(forKey: key) }
    func clearPropertyText(_ key: FieldKey) { propertyTextDrafts.removeValue(forKey: key) }

    func setPropertyPreview(_ value: BridgePropertyValue, key: FieldKey) { propertyPreviewValues[key] = value }

    /// Drops the value being dragged for one property. Returns whether there was one.
    @discardableResult
    func clearPropertyPreview(_ key: FieldKey) -> Bool { propertyPreviewValues.removeValue(forKey: key) != nil }

    /// Drops every value being dragged for a wallpaper, its Wallpaper Engine options' included.
    /// Returns whether there was one.
    @discardableResult
    func clearPropertyPreviews(wallpaperID: String) -> Bool {
        let before = propertyPreviewValues.count + engineOptionPreviewValues.count
        propertyPreviewValues = propertyPreviewValues.filter { $0.key.wallpaperID != wallpaperID }
        engineOptionPreviewValues = engineOptionPreviewValues.filter { $0.key.wallpaperID != wallpaperID }
        return propertyPreviewValues.count + engineOptionPreviewValues.count != before
    }

    /// Drops the values being dragged for every wallpaper but one. Returns the wallpapers that had some.
    func clearPropertyPreviews(except wallpaperID: String) -> Set<String> {
        let others = Set(propertyPreviewValues.keys.map(\.wallpaperID))
            .union(engineOptionPreviewValues.keys.map(\.wallpaperID)).subtracting([wallpaperID])
        propertyPreviewValues = propertyPreviewValues.filter { $0.key.wallpaperID == wallpaperID }
        engineOptionPreviewValues = engineOptionPreviewValues.filter { $0.key.wallpaperID == wallpaperID }
        return others
    }

    func setEngineOptionPreview(_ value: BridgePropertyValue, key: EngineFieldKey) {
        engineOptionPreviewValues[key] = value
    }

    /// Drops the value being dragged for one Wallpaper Engine option. Returns whether there was one.
    @discardableResult
    func clearEngineOptionPreview(_ key: EngineFieldKey) -> Bool {
        engineOptionPreviewValues.removeValue(forKey: key) != nil
    }

    /// Drops the values being dragged for every Wallpaper Engine option of a wallpaper. Returns
    /// whether there was one.
    @discardableResult
    func clearEngineOptionPreviews(wallpaperID: String) -> Bool {
        let before = engineOptionPreviewValues.count
        engineOptionPreviewValues = engineOptionPreviewValues.filter { $0.key.wallpaperID != wallpaperID }
        return engineOptionPreviewValues.count != before
    }

    /// The Wallpaper Engine option values the bridge is told to show on top of the draft, in a
    /// fixed order.
    func engineOptionPreviews(wallpaperID: String) -> [BridgeEngineOptionEdit] {
        engineOptionPreviewValues.filter { $0.key.wallpaperID == wallpaperID }
            .sorted { "\($0.key.option)" < "\($1.key.option)" }
            .map { BridgeEngineOptionEdit(option: $0.key.option, value: $0.value) }
    }

    /// What the bridge is told to show on top of the wallpaper's draft, in a fixed order.
    func propertyPreviews(wallpaperID: String) -> [BridgePropertyEdit] {
        propertyPreviewValues.filter { $0.key.wallpaperID == wallpaperID }
            .sorted { $0.key.fieldID < $1.key.fieldID }
            .map { BridgePropertyEdit(propertyId: $0.key.fieldID, value: $0.value) }
    }

    func hasPendingEdits(wallpaperID: String) -> Bool {
        scalingDrafts.keys.contains { $0.wallpaperID == wallpaperID }
            || propertyTextDrafts.keys.contains { $0.wallpaperID == wallpaperID }
    }

    func hasInvalidScaling(wallpaperID: String) -> Bool {
        scalingDrafts.contains { $0.key.wallpaperID == wallpaperID && $0.value.value == nil }
    }

    func discard(wallpaperID: String) {
        scalingDrafts = scalingDrafts.filter { $0.key.wallpaperID != wallpaperID }
        propertyTextDrafts = propertyTextDrafts.filter { $0.key.wallpaperID != wallpaperID }
        clearPropertyPreviews(wallpaperID: wallpaperID)
    }
    func reconcile(wallpaperID: String, displayIDs: Set<String>? = nil, textPropertyIDs: Set<String>) {
        if let displayIDs {
            scalingDrafts = scalingDrafts.filter { $0.key.wallpaperID != wallpaperID || displayIDs.contains($0.key.fieldID) }
        }
        propertyTextDrafts = propertyTextDrafts.filter { $0.key.wallpaperID != wallpaperID || textPropertyIDs.contains($0.key.fieldID) }
    }
}
