import Foundation

/// Text as Installed's search compares it: case, accents and character width are folded away, so
/// "cafe" finds "Café", "neon city" finds "ＮＥＯＮ　Ｃｉｔｙ" and "ｶﾌｪ" finds "カフェ". Kana keep their
/// voicing marks: "ハス" does not find "バス".
///
/// A wallpaper's words are folded once, when its manifest is read in the background or its row is
/// built, and a typed query once per pass over the library; matching is then a byte search, quick
/// enough for a 10,000-wallpaper library at every keystroke. Folding uses no locale, so words
/// folded in the background and a query folded in the panel agree whatever the panel's language.
enum LibrarySearchText {
    /// `text` in its compatibility forms (full-width letters and spaces, ligatures), case-folded,
    /// without diacritics and recomposed, so equal text is equal bytes.
    static func fold(_ text: String) -> String {
        // ASCII has no accents or compatibility forms, and its case folding is lower-casing.
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// Whether `text` holds `query`, both already folded. A UTF-8 byte search never starts inside a
    /// code point, so it finds what a search by code point would.
    static func contains(_ text: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var text = text
        var query = query
        return text.withUTF8 { haystack in
            query.withUTF8 { needle in
                haystack.count >= needle.count
                    && memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}
