import Foundation

/// One page of a pixiv work on its way into the library, as the tiles, the inspector and the
/// shared Downloads list read it: copied out of the live `PixivDownload` so the rules over it are
/// plain values.
struct PixivDownloadRow: Identifiable, Equatable {
  /// The library id the page is saved as (`pixiv-<work>-p<page>`), which also names the job.
  let id: String
  let work: PixivWork
  let pageIndex: Int
  let status: PixivDownload.Status
  let bytesReceived: Int64
  /// What the server announced; nil until it has.
  let bytesExpected: Int64?

  init(
    work: PixivWork, pageIndex: Int, status: PixivDownload.Status, bytesReceived: Int64 = 0,
    bytesExpected: Int64? = nil
  ) {
    id = work.libraryID(page: pageIndex)
    self.work = work
    self.pageIndex = pageIndex
    self.status = status
    self.bytesReceived = bytesReceived
    self.bytesExpected = bytesExpected
  }

  @MainActor
  init(_ download: PixivDownload) {
    self.init(
      work: download.work, pageIndex: download.pageIndex, status: download.status,
      bytesReceived: download.bytesReceived, bytesExpected: download.bytesExpected)
  }

  var title: String { work.title }

  /// Waiting, downloading or installing.
  var isPending: Bool {
    switch status {
    case .waiting, .downloading, .installing: true
    case .paused, .finished, .cancelled, .failed: false
    }
  }

  /// The received share of the announced size; nil until the server announced one.
  var progress: Double? {
    guard let bytesExpected, bytesExpected > 0 else { return nil }
    return min(1, Double(bytesReceived) / Double(bytesExpected))
  }

  /// The progress as a whole percentage, or nil while it is unknown.
  var percent: Int? { progress.map { Int((min(max($0, 0), 1) * 100).rounded()) } }

  var errorMessage: String? {
    if case .failed(let message) = status { message } else { nil }
  }

  /// What the shared Downloads list says about the save.
  @MainActor
  var queueStatus: String {
    switch status {
    case .paused: L("Download paused")
    case .waiting: L("Waiting to download")
    case .installing: L("Saving to your library…")
    case .finished: L("In your library")
    case .failed(let message): message
    case .cancelled: L("Download cancelled.")
    case .downloading: L("Downloading")
    }
  }

  /// The inspector's line under the progress bar: the state, and while bytes arrive how many of
  /// the announced total.
  @MainActor
  func inspectorStatus(locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    let state: String
    switch status {
    case .paused: state = L("Download paused")
    case .waiting: state = L("Waiting to download")
    case .installing: state = L("Saving to your library…")
    case .downloading, .finished, .cancelled, .failed:
      state = percent.map { L("Downloading \($0)%") } ?? L("Downloading")
    }
    guard status == .downloading, bytesReceived > 0, let announced = bytesExpected, announced > 0
    else { return state }
    let received = TransferFormat.bytes(Double(bytesReceived), locale: locale)
    let expected = TransferFormat.bytes(Double(announced), locale: locale)
    let amount = L("\(received) of \(expected)")
    return "\(state) · \(amount)"
  }
}
