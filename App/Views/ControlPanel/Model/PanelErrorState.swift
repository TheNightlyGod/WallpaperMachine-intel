import Foundation
import Observation

/// The panel's error line and its download counterpart: what they say, and what a dismissal
/// hides.
///
/// A dismissal suppresses exactly the message the user dismissed. A later, different failure
/// surfaces again, and clearing the source re-arms it, so the same failure happening after a
/// recovery is shown instead of staying hidden. The sources are other stores, read live, so
/// `message` and `downloadMessage` need no refresh of their own; `reconcile()` only forgets
/// dismissals whose source has gone, and the controller runs it whenever one of them changes.
///
/// Not part of this line, on purpose: a per-property path failure (beside its control), a preset or
/// backup status, a host-wallpaper retry (on its tile) and a preview-step refusal (ignored).
@MainActor
@Observable
final class PanelErrorState {
  /// What a thrown action said, until a Dismiss or the next direct or queued action clears it.
  /// An action that handles its own failures never reaches here.
  var actionError: String?
  /// The newest bridge error already dismissed, by revision.
  private(set) var dismissedBridgeRevision: UInt64 = 0
  private(set) var dismissedLibraryError: String?
  private(set) var dismissedDownloadError: String?

  @ObservationIgnored private let store: BridgeStore
  @ObservationIgnored private let imports: LibraryImportStore
  @ObservationIgnored private let workshop: WorkshopStore
  @ObservationIgnored private let pixiv: PixivStore

  init(
    store: BridgeStore, imports: LibraryImportStore, workshop: WorkshopStore, pixiv: PixivStore
  ) {
    self.store = store
    self.imports = imports
    self.workshop = workshop
    self.pixiv = pixiv
  }

  /// Why the library could not load, whether or not the user dismissed it.
  var libraryFailureMessage: String? {
    if case .failed(let message) = store.libraryLoadState { message } else { nil }
  }

  /// What the Workshop downloads and the pixiv queue last failed with, whether or not the user
  /// dismissed it: the downloader's own failure, else a queue that could not be saved.
  var downloadFailureMessage: String? {
    workshop.downloader.errorMessage ?? workshop.downloadPersistenceError
      ?? pixiv.downloads.persistenceError
  }

  /// The banner's text: the first of the action error, a failed import, the library failure
  /// (unless dismissed) and the newest bridge error (unless dismissed).
  var message: String? {
    actionError ?? imports.failure
      ?? (libraryFailureMessage == dismissedLibraryError ? nil : libraryFailureMessage)
      ?? (store.latestBridgeErrorRevision > dismissedBridgeRevision
        ? store.latestBridgeErrorMessage : nil)
  }

  /// The download error line's text, unless the user dismissed this very message.
  var downloadMessage: String? {
    let message = downloadFailureMessage
    return message == dismissedDownloadError ? nil : message
  }

  /// Shows what a failed action threw. A cancellation is the window going away, not a failure.
  func report(_ error: Error) {
    guard !(error is CancellationError) else { return }
    actionError = error.localizedDescription
  }

  /// Clears the banner before a direct or queued action starts, as every such action does. An
  /// action that browses or cancels leaves an older banner showing, so it does not call this.
  func clearAction() { actionError = nil }

  /// The Dismiss button. Hides what the banner and the download line show now; a failure that
  /// comes later, or the same one after its source recovered, is shown again.
  func dismiss() {
    actionError = nil
    imports.dismissFailure()
    dismissedBridgeRevision = store.latestBridgeErrorRevision
    dismissedLibraryError = libraryFailureMessage
    dismissedDownloadError = downloadFailureMessage
  }

  /// Forgets a dismissal whose source no longer has an error, so that source can speak again.
  func reconcile() {
    if libraryFailureMessage == nil { dismissedLibraryError = nil }
    if downloadFailureMessage == nil { dismissedDownloadError = nil }
  }

  /// Everything `reconcile()` reads, for an observation that re-runs it when a source changes.
  func trackSources() {
    _ = libraryFailureMessage
    _ = downloadFailureMessage
  }
}
