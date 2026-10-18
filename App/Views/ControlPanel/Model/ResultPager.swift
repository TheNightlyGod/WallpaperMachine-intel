import Foundation

/// The paging bar of a result grid, with the rules Discover's Steam list and pixiv's listings share.
///
/// A source serves at most `maxPages` pages (Steam and pixiv both stop at 1,000). A count of zero,
/// or a page past the end, still leaves one page to show, and every control waits while a page
/// loads. A typed page number is rounded and clamped into range, and one that names the page
/// already on show asks for nothing.
struct ResultPager: Equatable {
  let page: Int
  /// The source's own count, which may be zero before the first page arrives.
  let totalPages: Int
  let isLoading: Bool
  /// The most pages the source serves.
  let maxPages: Int

  /// The pages the bar offers: at least one, never more than the source serves.
  var pages: Int { min(maxPages, max(1, totalPages)) }
  var canGoBack: Bool { !isLoading && page > 1 }
  var canGoForward: Bool { !isLoading && page < pages }
  /// The number field and its Go button have somewhere else to go only past one page.
  var canJump: Bool { !isLoading && pages > 1 }
  var previousPage: Int { max(1, page - 1) }
  var nextPage: Int { min(pages, page + 1) }

  /// `number` brought into the pages the bar offers.
  func clamped(_ number: Int) -> Int { min(pages, max(1, number)) }

  /// The page a typed number asks for, or nil when it asks for nothing: the page already on show,
  /// or any page while one loads. Text that is not a number asks for the first page, as an empty
  /// field does.
  func jumpTarget(typed text: String) -> Int? {
    jumpTarget(to: Double(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// `jumpTarget(typed:)` for a field that already parsed its number; nil is the first page.
  func jumpTarget(to value: Double?) -> Int? {
    let rounded = (value ?? 0).rounded(.toNearestOrAwayFromZero)
    let number = rounded.isNaN || rounded == 0 ? 1 : rounded
    // Clamp as a Double: an absurdly large number must not trap in the conversion.
    let target = Int(min(Double(pages), max(1, number)))
    return target != page && !isLoading ? target : nil
  }
}
