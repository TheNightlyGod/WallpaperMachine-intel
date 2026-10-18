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
  @State private var loaded: (request: Request, image: DecodedPanelImage)?

  private struct Request: Hashable {
    let source: PanelImageSource
    let pixels: Int
  }

  private var request: Request? {
    source.map { Request(source: $0, pixels: max(16, Int((pointSize * displayScale).rounded(.up)))) }
  }

  private var displayed: DecodedPanelImage? {
    guard let request else { return nil }
    if let loaded, loaded.request == request { return loaded.image }
    return images?.cachedImage(for: request.source, maxPixelSize: request.pixels)
  }

  var body: some View {
    Color.primary.opacity(0.06)
      .overlay {
        if let image = displayed {
          Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: contentMode)
        }
      }
      .clipped()
      .task(id: request) { await load() }
  }

  private func load() async {
    guard let request, let images else { return }
    if loaded?.request == request { return }
    if images.cachedImage(for: request.source, maxPixelSize: request.pixels) != nil { return }
    guard let image = try? await images.image(for: request.source, maxPixelSize: request.pixels)
    else { return }
    guard !Task.isCancelled else { return }
    loaded = (request, image)
  }
}
