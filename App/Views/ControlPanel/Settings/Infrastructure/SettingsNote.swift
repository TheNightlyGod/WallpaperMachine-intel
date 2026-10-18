import Foundation

/// Cuts a long explanation into the sentence that stays under a row's title and the rest, which
/// waits behind the row's ⓘ button.
///
/// A port of the web panel's `noteParts`: weighting each CJK character double keeps the cut
/// comparable across languages.
enum SettingsNote {
  /// A note that weighs no more than this stays whole under its title.
  static let wholeNoteWeight = 120
  /// A first sentence lighter than this is too little to stand alone ("Experimental."), so the lead
  /// takes the next sentence too.
  static let leadWeight = 36

  /// One for each character, two for each Han, kana or full-width character.
  static func weight(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { sum, scalar in
      sum + ((0x2E80...0xFFEF).contains(scalar.value) ? 2 : 1)
    }
  }

  /// The lead that stays under the title, and what is left for the ⓘ button, or nil when the note
  /// is short enough to stay whole or has no sentence end to cut at.
  static func parts(_ note: String) -> (lead: String, more: String?) {
    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard weight(text) > wholeNoteWeight else { return (text, nil) }
    let characters = Array(text)
    for index in characters.indices {
      let character = characters[index]
      let next = characters.indices.contains(index + 1) ? characters[index + 1] : nil
      let endsSentence =
        "。！？".contains(character)
        || (".!?".contains(character) && (next == nil || next!.isWhitespace))
      guard endsSentence else { continue }
      let lead = String(characters[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
      if weight(lead) < leadWeight { continue }
      let more = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      return more.isEmpty ? (text, nil) : (lead, more)
    }
    return (text, nil)
  }
}
