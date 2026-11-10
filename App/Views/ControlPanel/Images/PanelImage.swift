import SwiftUI

extension EnvironmentValues {
  /// The pipeline `PanelImage` loads through. The root view sets it from the controller; without
  /// one, an image shows its placeholder.
  @Entry var panelImages: PanelImagePipeline?
}

/// A still from the pipeline: loads when it appears or its source changes, stops waiting when it
/// disappears, and shows a placeholder until the image is ready.
///
/// The view takes whatever size its parent proposes and clips the image to it, so an image
/// arriving never moves anything. `pointSize` is the long side of the largest the image will be
/// drawn, in points; the decode is that times the display scale, so a grid tile never holds a
/// full-size preview. A view that has changed source shows the placeholder, never the previous
/// source's image, and a source whose still is already in memory shows it in its first frame.
struct PanelImage: View {
  let source: PanelImageSource?
  var pointSize: CGFloat = 160
  var contentMode: ContentMode = .fill

  @Environment(\.panelImages) private var images
  @Environment(\.displayScale) private var displayScale
  @State private var state = ImageState()

  fileprivate struct Request: Hashable {
    let source: PanelImageSource
    let pixels: Int
  }

  // A reference keeps old SwiftUI view snapshots from retaining a previous decoded image.
  @Observable fileprivate final class ImageState {
    var loaded: (request: Request, image: DecodedPanelImage)?
    /// The request whose load failed, so the view can say there is no picture to show.
    var failed: Request?
    var isActive = true
  }

  private var request: Request? {
    source.map { Request(source: $0, pixels: max(16, Int((pointSize * displayScale).rounded(.up)))) }
  }

  private var displayed: DecodedPanelImage? {
    guard state.isActive, let request else { return nil }
    if let loaded = state.loaded, loaded.request == request { return loaded.image }
    return images?.cachedImage(for: request.source, maxPixelSize: request.pixels)
  }

  /// The load of what the view shows now failed: a missing or unreadable file, a download that
  /// did not arrive. Without a mark it would look like an image that is still on its way.
  private var hasFailed: Bool {
    guard state.isActive, let request else { return false }
    return state.failed == request
  }

  var body: some View {
    Color.primary.opacity(0.06)
      .overlay {
        if let image = displayed {
          Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: contentMode)
        } else if hasFailed {
          Image(systemName: "photo")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .clipped()
      .task(id: request) { await load() }
      // Lazy grids keep row state after disappearance; only the bounded cache should keep pixels.
      // Reactivating on appear, not in the task, lets a returning row show a cached still in its
      // first frame instead of the placeholder.
      .onAppear { state.isActive = true }
      .onDisappear {
        state.isActive = false
        state.loaded = nil
        state.failed = nil
      }
  }

  private func load() async {
    guard !Task.isCancelled else { return }
    guard let request, let images else {
      state.loaded = nil
      state.failed = nil
      return
    }
    if state.loaded?.request == request { return }
    state.loaded = nil
    state.failed = nil
    do {
      let image = try await images.image(for: request.source, maxPixelSize: request.pixels)
      guard !Task.isCancelled else { return }
      state.loaded = (request, image)
    } catch {
      // A load that was cancelled (the view left, the source changed) did not fail.
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      state.failed = request
    }
  }
}
