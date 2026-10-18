import Foundation

/// The title bar's note that pixiv saves are under way, which shows on every page and leads back
/// to the pixiv page. pixiv saves are the app's own and brief, so they are not a separate list.
struct PixivActivity: Equatable {
  /// The works being saved: pending jobs, waiting ones included.
  let jobCount: Int
  /// With exactly one job, its work's title (empty for a work without one) and progress.
  let title: String?
  let percent: Int?

  /// Nil when no pixiv save is pending.
  init?(_ jobs: [PixivDownloadRow]) {
    let pending = jobs.filter(\.isPending)
    guard let first = pending.first else { return nil }
    jobCount = pending.count
    title = pending.count == 1 ? first.title : nil
    percent = pending.count == 1 ? first.percent : nil
  }

  /// "pixiv: Title · 42%", or "3 pixiv downloads" for several.
  @MainActor
  var label: String {
    guard let title else { return L("\(jobCount) pixiv downloads") }
    let name = title.isEmpty ? L("Untitled") : title
    let summary = L("pixiv: \(name)")
    return percent.map { "\(summary) · \($0)%" } ?? summary
  }
}
