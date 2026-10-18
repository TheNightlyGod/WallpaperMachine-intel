import Foundation

/// The selected work as the inspector shows it: the page on show, how many pages there are and
/// whether their list is known yet, whether the page is saved, and what its download offers.
struct PixivSelection: Equatable {
  /// The work's page list: a listing may predate pages added since, so once fetched it decides.
  enum Pages: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  let work: PixivWork
  /// The page the inspector shows and would download.
  let pageIndex: Int
  let pageCount: Int
  let pages: Pages
  /// The page's 540 px rendition, once the page list has one for it; the listing's thumbnail
  /// stands in until then.
  let preview: PanelImageSource?
  let thumbnail: PanelImageSource?
  /// The page's own size, else the work's for the first page, else 0.
  let pageWidth: Int
  let pageHeight: Int
  /// The wallpaper id the page is saved as.
  let libraryID: String
  /// Page indexes of the work that are in the library.
  let savedPages: [Int]
  /// The download job of the page on show, in any state.
  let job: PixivDownloadRow?

  /// The page on show is in the library: the inspector offers to apply it instead of downloading.
  var isSaved: Bool { savedPages.contains(pageIndex) }

  /// What the inspector's download area offers, in this order: nothing for a saved page; pause
  /// and cancel for a pending job; resume and cancel for a paused one; otherwise a Download button.
  var download: Download {
    if isSaved { return .saved }
    if let job {
      if job.isPending { return .pending(job) }
      if job.status == .paused { return .paused(job) }
    }
    if !(job?.errorMessage ?? "").isEmpty { return .available(.again) }
    return .available(pageCount > 1 ? .page(pageIndex + 1) : .plain)
  }

  enum Download: Equatable {
    /// The page is in the library; the inspector shows Apply and Show in library instead.
    case saved
    case pending(PixivDownloadRow)
    case paused(PixivDownloadRow)
    case available(Label)

    /// How the Download button reads.
    enum Label: Equatable {
      /// "Download"
      case plain
      /// "Download page 2": a work with several pages says which.
      case page(Int)
      /// "Download again", after a failure.
      case again
    }
  }

  /// The failure of the page's last download, shown for a page that is not saved.
  var failure: String? {
    guard !isSaved, let job, !job.isPending, let message = job.errorMessage, !message.isEmpty
    else { return nil }
    return message
  }
}

/// What double-clicking a pixiv tile does: download the page the inspector shows (the first, until
/// it shows another), apply it once it is saved, and nothing while it downloads or when no
/// display could show it.
enum PixivDoubleClick: Equatable {
  case apply(libraryID: String)
  case download(workID: String, page: Int)
  case nothing

  /// - Parameters:
  ///   - selection: the inspector's selection, which names the page when it is this work.
  ///   - savedPages: the saved pages of this work.
  ///   - pendingJobIDs: the library ids of the downloads that are under way or waiting.
  ///   - targetCanShowWallpaper: the target display is enabled and shows a wallpaper of its own.
  static func decide(
    workID: String, selection: PixivSelection?, savedPages: [Int], pendingJobIDs: Set<String>,
    targetCanShowWallpaper: Bool
  ) -> PixivDoubleClick {
    let page = selection?.work.id == workID ? selection?.pageIndex ?? 0 : 0
    return decide(
      workID: workID, page: page, savedPages: savedPages, pendingJobIDs: pendingJobIDs,
      targetCanShowWallpaper: targetCanShowWallpaper)
  }

  /// The same rule for a page already known: the one the inspector shows when it shows this work,
  /// else the first. A tile names its double-click for VoiceOver with it, without building the
  /// inspector's selection (which reads the progress of the selected page's download).
  static func decide(
    workID: String, page: Int, savedPages: [Int], pendingJobIDs: Set<String>,
    targetCanShowWallpaper: Bool
  ) -> PixivDoubleClick {
    let libraryID = PixivWork.libraryID(workID: workID, page: page)
    if savedPages.contains(page) {
      return targetCanShowWallpaper ? .apply(libraryID: libraryID) : .nothing
    }
    if pendingJobIDs.contains(libraryID) { return .nothing }
    return .download(workID: workID, page: page)
  }
}
