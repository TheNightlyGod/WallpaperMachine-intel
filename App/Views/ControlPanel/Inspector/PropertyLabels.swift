import Foundation

/// How a wallpaper's property labels and combo choices become the words the inspector shows.
///
/// A label is the author's markup, which the inspector treats as data and never as its own: the
/// plain words in it name a control for accessibility and for the file pickers, and a rich renderer
/// (the inspector's, which owns the allowlist) draws the markup itself. Wallpaper Engine's built-in
/// `ui_…` label tokens are UI vocabulary instead of author prose, so they are shown as words: a
/// curated phrase where one reads better than the derived words, else the words derived from the
/// token. Both are translated when the phrase is an entry of the catalog.
enum PropertyLabels {
  /// A label ready to show: the words, and the author's markup when the words are the author's.
  struct Presentation: Equatable {
    /// The plain words; empty when the label carries none (pure decoration).
    let text: String
    /// The author's untrusted markup, for the rich renderer; nil when `text` came from the app (a
    /// curated phrase, derived words or a packaged still's label), which has no markup to draw.
    let markup: String?
    /// The allowlisted `<img src>` spellings in `markup` and where they live. Only a registered
    /// source is ever loaded, through `PanelImageSource.propertyImage`.
    let images: [String: URL]

    /// Nothing to show: no words and no artwork.
    var isEmpty: Bool { text.isEmpty && images.isEmpty }
  }

  /// Wallpaper Engine's own tokens whose derived words are not the intended phrase, or that need a
  /// fixed one. A token with no entry is shown as the words derived from it.
  static let curatedPhrases: [String: String] = [
    "ui_browse_properties_scheme_color": "Scheme color",
    "ui_editor_properties_alert_tip": "Hint",
    "ui_editor_effect_local_contrast_title": "Local contrast",
    "ui_editor_properties_brightness": "Brightness",
    "ui_editor_properties_default": "Default",
    "ui_editor_properties_left": "Left",
    "ui_editor_properties_right": "Right",
    "ui_editor_properties_position": "Position",
    "ui_editor_layer_solid": "Solid color",
    "ui_editor_properties_size": "Size",
    "ui_settings_enable_media_integration_support": "Media integration",
    "ui_editor_script_snippets": "Script snippets",
    "ui_editor_preset_stars_title": "Stars",
    "ui_editor_properties_pivot_offset_x": "Pivot offset X",
    "ui_editor_properties_pivot_offset_y": "Pivot offset Y",
    "ui_editor_properties_use_24h_format": "Use 24-hour format",
  ]

  /// The labels this app writes into the still images it packages (saved from pixiv or imported
  /// from disk). The manifest keeps them in English, as any wallpaper's are; being ours, they are
  /// translated for those wallpapers, which the library knows by their id.
  private static let packagedStillLabels: Set<String> = ["Image fit", "Background color"]

  private static func isPackagedStill(_ wallpaperID: String) -> Bool {
    wallpaperID.hasPrefix("pixiv-") || wallpaperID.hasPrefix("image-")
  }

  /// The shape of one of the editor's label tokens, as the page matched it.
  private static func isEditorToken(_ token: String) -> Bool {
    token.range(of: "^ui_[A-Za-z0-9_]{1,93}$", options: .regularExpression) != nil
  }

  /// What reading one label costs: four regular expressions for the words and one more for the
  /// artwork. The inspector reads its state whenever anything it shows changes, so the result for a
  /// label is kept, as the page kept its 256 rendered labels, and dropped wholesale at the limit.
  private struct Reading {
    let plain: String
    let images: [String: URL]
  }
  @MainActor private static var readings: [String: Reading] = [:]
  private static let readingLimit = 256

  @MainActor
  private static func reading(of html: String) -> Reading {
    if let known = readings[html] { return known }
    let reading = Reading(plain: plainLabel(html), images: PropertyImageCache.sources(in: html))
    if readings.count >= readingLimit { readings.removeAll(keepingCapacity: true) }
    readings[html] = reading
    return reading
  }

  /// The plain words of an author's label (see `plainLabel`), remembered.
  @MainActor
  static func plainWords(_ html: String) -> String { reading(of: html).plain }

  /// The presentation of a property label, in the language of `locale` (the panel's by default).
  @MainActor
  static func presentation(
    labelHTML: String, wallpaperID: String, locale: PanelLocale? = nil
  ) -> Presentation {
    let locale = locale ?? .shared
    let reading = reading(of: labelHTML)
    let plain = reading.plain
    // The scheme-colour token is the editor's marker for a colour it adds to every scene: its
    // markup is never shown, only the phrase.
    let token = labelHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    let engineLabel: String? =
      curatedPhrases[token]
      ?? (isPackagedStill(wallpaperID) && packagedStillLabels.contains(token) ? token : nil)
      // Any other built-in token arrives as words from the app; the same phrase in the catalog is
      // translated.
      ?? (isEditorToken(token) && !plain.isEmpty ? plain : nil)
    if let engineLabel {
      return Presentation(text: locale.catalogString(engineLabel), markup: nil, images: [:])
    }
    return Presentation(text: plain, markup: labelHTML, images: reading.images)
  }

  /// A combo choice's words: the editor's token worded, then the catalog's translation of the
  /// phrase. Only the label is rewritten; the choice's value is what the wallpaper reads.
  @MainActor
  static func choiceLabel(_ label: String, locale: PanelLocale? = nil) -> String {
    (locale ?? .shared).catalogString(engineTokenLabel(label) ?? label)
  }

  /// The plain words of an author's label, for accessibility and the file pickers.
  ///
  /// Block-level tags separate words, every other tag is dropped, indent entities (with or without
  /// the semicolon an author forgot) are whitespace, and an escaped ampersand is decoded once so
  /// escaped markup can never come back as markup. Empty decoration (an image strip, a rule)
  /// yields `""` and never falls back to the editor's markup-slug property id. The editor's tokens
  /// read as their derived words; the scheme-colour token as its phrase.
  nonisolated static func plainLabel(_ html: String) -> String {
    if html == "ui_browse_properties_scheme_color" { return "Scheme color" }
    if let words = engineTokenLabel(html) { return words }
    let spaced = html.replacingOccurrences(
      of: "<(br|hr|/p|/div|/li|/tr|/h[1-6])\\b[^>]*>", with: " ",
      options: [.regularExpression, .caseInsensitive])
    return
      spaced
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;?", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Leading words of a built-in token that name the editor screen it came from, not the thing.
  private static let areaWords: Set<String> = [
    "editor", "browse", "settings", "workshop", "properties", "user", "scene", "options", "tags",
    "type", "effect", "preset", "layer", "importer", "gizmo", "context", "menu", "modal", "welcome",
  ]
  /// Trailing words that only say the token was a heading or caption.
  private static let captionWords: Set<String> = ["title", "label", "text"]
  private static let maximumTokenLength = 96

  /// The words for one of Wallpaper Engine's own `ui_…` label tokens, which a project that carries
  /// no text for them leaves as the label or combo choice. Nil for anything else: author prose,
  /// markup, or a token too long to be the editor's. Presentation only; the stored label and the
  /// choice's value are never rewritten. The words are English; the panel translates them when the
  /// same phrase is a catalog entry.
  nonisolated static func engineTokenLabel(_ text: String) -> String? {
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count <= maximumTokenLength, token.hasPrefix("ui_") else { return nil }
    let body = token.dropFirst(3)
    guard !body.isEmpty,
      body.unicodeScalars.allSatisfy({
        $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0))
      })
    else { return nil }
    var words = body.split(separator: "_").map(String.init)
    while words.count > 1, areaWords.contains(words[0].lowercased()) { words.removeFirst() }
    while words.count > 1, let last = words.last, captionWords.contains(last.lowercased()) {
      words.removeLast()
    }
    guard !words.isEmpty else { return nil }
    let joined = words.joined(separator: " ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }
}
