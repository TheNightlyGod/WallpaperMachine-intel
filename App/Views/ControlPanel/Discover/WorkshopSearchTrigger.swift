import Foundation

/// When an edit of the Workshop search field starts a search.
///
/// Typing searches after a short pause, so a word is looked up once and not letter by letter. A
/// link pasted or dropped whole is looked up at once: it is complete the moment it arrives. A bare
/// item id of six digits or more waits for Return, because Steam would otherwise look up every
/// prefix of it as someone typed it. Return always searches now.
enum WorkshopSearchTrigger: Equatable {
  /// Search immediately.
  case now
  /// Search after `pause` with no further edit.
  case afterPause
  /// Do nothing until the person presses Return.
  case onReturn

  /// How long typing rests before it searches.
  static let pause: Duration = .milliseconds(450)

  /// Whether the field's prompt invites a pasted link: only the Wallpapers list looks one up.
  static func invitesLink(for source: WorkshopSource) -> Bool { source == .browse }

  /// What an edit that left `text` in the field starts. `isPasteOrDrop` says the edit put the
  /// whole text there in one step (see `isPasteOrDrop(from:to:)`). Empty text is not an id, so
  /// clearing the field searches after the pause.
  static func classify(_ text: String, isPasteOrDrop: Bool) -> WorkshopSearchTrigger {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if isPasteOrDrop && isLink(trimmed) { return .now }
    return isBareID(trimmed) ? .onReturn : .afterPause
  }

  /// An `http`, `https` or `steam` link with something after the scheme and no whitespace in it.
  static func isLink(_ text: String) -> Bool {
    let lowered = text.lowercased()
    for scheme in ["https://", "http://", "steam://"] where lowered.hasPrefix(scheme) {
      let rest = lowered.dropFirst(scheme.count)
      return !rest.isEmpty && !rest.contains(where: \.isWhitespace)
    }
    return false
  }

  /// Six or more ASCII digits and nothing else: what Steam reads as an item id.
  static func isBareID(_ text: String) -> Bool {
    text.count >= 6 && text.allSatisfy { ("0"..."9").contains($0) }
  }

  /// Whether the edit from `old` to `new` inserted more than one character at once, which only a
  /// paste, a drop or an autocompletion does: a typed character, even one that replaces a
  /// selection, inserts exactly one. A text field cannot say how its text arrived, so the change
  /// is read off the two strings.
  static func isPasteOrDrop(from old: String, to new: String) -> Bool {
    let before = Array(old)
    let after = Array(new)
    var prefix = 0
    while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < before.count - prefix, suffix < after.count - prefix,
      before[before.count - 1 - suffix] == after[after.count - 1 - suffix]
    {
      suffix += 1
    }
    return after.count - prefix - suffix > 1
  }
}
