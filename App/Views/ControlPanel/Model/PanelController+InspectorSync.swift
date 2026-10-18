import Foundation

/// The side effects the web panel ran while it built each snapshot, made explicit.
///
/// Building a snapshot selected the compatibility and Black bars context, forgot a staged scale
/// factor that no longer held and measured chosen folders. Reading state from a SwiftUI body must
/// not mutate observable state, so the derived getters only read, and these effects run here: from
/// an observation of what they depend on, and from the end of an action that changes the draft. A
/// test calls `reconcileInspectorContext()` by hand at the point the page would have rebuilt.
extension PanelController {
  /// Brings the stores that hold per-selection results in line with what is selected now.
  ///
  /// - The compatibility store drops a result (and cancels one still being read) when the selected
  ///   wallpaper, the target display, the display's frame rate, the library or the assets folder
  ///   changed under it.
  /// - A Black bars probe still running for another wallpaper is cancelled.
  /// - The scale factor the Black bars card staged is forgotten once it can no longer be the
  ///   unsaved part of the draft (applied, reverted, edited, or the selection or target moved):
  ///   a later unrelated edit must not bring the claim back.
  /// - The folders the open wallpaper's properties point at are measured once per path.
  func reconcileInspectorContext() {
    compatibility.select(compatibilityContext())
    letterbox.select(store.appSnapshot.selectedWallpaperId)
    forgetLetterboxStagedFactor(unlessHeldIn: letterboxContext())
    if let options = store.wallpaperOptionsSnapshot { _ = measuredAssets(for: options) }
  }

  /// Keeps `reconcileInspectorContext()` running while the panel is started. An inspector starts it
  /// by reading its state. A second call does nothing, and a panel that was never started has no
  /// observation. The loop ends itself at the first change after the panel stopped, so `stop()` need
  /// not call `stopInspectorContextObservation()`, though it may.
  func startInspectorContextObservation() {
    guard isStarted, inspectorContextLoop == nil else { return }
    let loop = ObservationLoop(
      track: { [weak self] in self?.trackInspectorContext() },
      onChange: { [weak self] in
        guard let self else { return }
        guard self.isStarted else { return self.stopInspectorContextObservation() }
        self.reconcileInspectorContext()
      })
    inspectorContextLoop = loop
    loop.start()
    // The first read may come from a view update, which must not change state: reconcile later.
    Task { @MainActor [weak self] in self?.reconcileInspectorContext() }
  }

  /// Ends the observation.
  func stopInspectorContextObservation() {
    inspectorContextLoop?.stop()
    inspectorContextLoop = nil
  }

  /// What the context depends on, for the observation.
  private func trackInspectorContext() {
    _ = store.appSnapshot
    _ = store.librarySnapshot
    _ = store.wallpaperOptionsSnapshot
    _ = store.settingsSnapshot
    _ = store.libraryRefreshRevision
    _ = revisions.navigation
  }
}
