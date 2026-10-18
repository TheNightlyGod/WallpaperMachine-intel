import Observation

/// The inspector of the selected wallpaper: the state its views keep that the controller does not.
///
/// What the options, properties, presets, placement, compatibility and Black bars cards show comes
/// from the controller's typed getters, and the actions they start are the controller's (the
/// Downloads list opens through `controller.downloads`). This holds the rest: the coalescing queue
/// of the Position on screen frame. The disclosure state, the presets bar's picks and the field
/// drafts live in the views of one wallpaper (the inspector's content is keyed by the wallpaper's
/// id), so another wallpaper starts with the defaults.
@MainActor
@Observable
final class InspectorModel {
  unowned let controller: PanelController

  /// The Position on screen frame's drafts and send queue.
  @ObservationIgnored lazy var placement = PlacementDrafts(
    current: { [unowned self] in self.controller.imagePlacementState },
    send: { [unowned self] request in await self.sendPlacement(request) },
    reset: { [unowned self] target in await self.resetPlacement(target) })

  init(controller: PanelController) { self.controller = controller }

  // MARK: Placement actions

  private func sendPlacement(_ request: PlacementDrafts.Request) async -> Bool {
    let box = Outcome<Void>()
    let controller = controller
    await controller.launch(
      InspectorAction.imagePlacement(request.target.wallpaperID, display: request.target.displayID)
    ) {
      box.ran = true
      do {
        try await controller.setImagePlacement(
          request.target.wallpaperID, display: request.target.displayID, x: request.x,
          y: request.y, zoom: request.zoom)
      } catch {
        box.failed = true
        throw error
      }
    }.value
    return box.ran && !box.failed
  }

  private func resetPlacement(_ target: PlacementDrafts.Target) async -> Bool {
    let box = Outcome<Void>()
    let controller = controller
    await controller.launch(InspectorAction.imagePlacement(target.wallpaperID, display: target.displayID)) {
      box.ran = true
      do {
        try await controller.resetImagePlacement(target.wallpaperID, display: target.displayID)
      } catch {
        box.failed = true
        throw error
      }
    }.value
    return box.ran && !box.failed
  }
}
