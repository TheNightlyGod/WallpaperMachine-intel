import Foundation

/// What a pixiv tile says about its work beyond the picture: the badges in its corner and the
/// facts VoiceOver reads after the title.
struct PixivTileFacts: Equatable {
  /// "#3": the position in a ranking.
  let rank: Int?
  /// The work is Mature (R-18). Questionable works carry no badge; the inspector says so.
  let isMature: Bool
  /// The pages of a work that has several; nil for a single page.
  let pageCount: Int?
  let isSaved: Bool
  /// "by Artist, Ranked #3, Mature (R-18), 2 pages, In your library", in that order and only what
  /// applies. Selection is carried by the tile's own accessibility trait.
  let spoken: String

  @MainActor
  init(_ tile: PixivTile) {
    let work = tile.work
    rank = work.rank
    isMature = work.rating == .mature
    pageCount = work.pageCount > 1 ? work.pageCount : nil
    isSaved = tile.isSaved
    var facts: [String] = []
    if !work.authorName.isEmpty { facts.append(L("by \(work.authorName)")) }
    if let rank { facts.append(L("Ranked #\(rank)")) }
    if isMature { facts.append(L("Mature (R-18)")) }
    if let pageCount { facts.append(L("\(pageCount) pages")) }
    if isSaved { facts.append(L("In your library")) }
    spoken = facts.joined(separator: ", ")
  }
}

/// Which of a tile's facts its corners show, for the room the tile has.
///
/// A roomy tile shows every mark that applies: the saved check top leading, the rank and R-18 top
/// trailing, the page count bottom trailing. Beside an open inspector at the smallest window a
/// tile is about 50 points wide, and those corners meet over the picture (the check sat on the
/// rank, two capsules filled the artwork). Under `compactSide` only the marks that change what the
/// person does stay, the saved check and R-18, drawn smaller and stacked in the leading corner so
/// they can never meet. The tile's accessibility label still says every fact.
struct PixivTileCorners: Equatable {
  /// Under this width, in points, a tile shows the compact marks.
  static let compactSide: CGFloat = 90

  let isCompact: Bool
  let showsSaved: Bool
  let showsMature: Bool
  /// The ranking badge; nil when unranked or when the tile has no room for it.
  let rank: Int?
  /// The page-count badge; nil for a single page or when the tile has no room for it.
  let pageCount: Int?

  init(_ facts: PixivTileFacts, isCompact: Bool) {
    self.isCompact = isCompact
    showsSaved = facts.isSaved
    showsMature = facts.isMature
    rank = isCompact ? nil : facts.rank
    pageCount = isCompact ? nil : facts.pageCount
  }

  static func isCompact(side: CGFloat) -> Bool { side < compactSide }
}

/// The inspector's line of facts under the title: the size of the page on show, how many pages
/// there are, and what the rating and the AI flag say.
enum PixivMeta {
  /// "1,920 × 1,080", "2 pages", "Questionable (PG-13)", "AI-generated": each only when it applies.
  /// A page's size is shown only once both sides are known.
  @MainActor
  static func parts(_ selection: PixivSelection, locale: Locale? = nil) -> [String] {
    let locale = locale ?? PanelLocale.shared.locale
    var parts: [String] = []
    if selection.pageWidth > 0, selection.pageHeight > 0 {
      let width = selection.pageWidth.formatted(.number.locale(locale))
      let height = selection.pageHeight.formatted(.number.locale(locale))
      parts.append("\(width) × \(height)")
    }
    if selection.pageCount > 1 { parts.append(L("\(selection.pageCount) pages")) }
    switch selection.work.rating {
    case .questionable: parts.append(L("Questionable (PG-13)"))
    case .mature: parts.append(L("Mature (R-18)"))
    case .everyone, .grotesque: break
    }
    if selection.work.aiGenerated == true { parts.append(L("AI-generated")) }
    return parts
  }
}

extension PixivWork {
  /// The artist's page on pixiv, when the id is one the allowlist opens.
  var authorProfileURL: URL? {
    guard !authorID.isEmpty, authorID.allSatisfy(\.isASCII), authorID.allSatisfy(\.isNumber)
    else { return nil }
    return ExternalLink.allowed("https://www.pixiv.net/users/\(authorID)")
  }
}
