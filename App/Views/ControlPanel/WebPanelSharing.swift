import AppKit
import Foundation

/// Sharing a wallpaper or the app, and the About star link. Every link here is built in
/// Swift from fixed parts; the page sends only a wallpaper id and where its button is, so
/// nothing it says becomes a URL.
@MainActor
extension WebPanelController {
  func performSharing(_ action: String, request: WebPanelRequest) async throws -> Bool {
    switch action {
    case "shareWallpaper":
      let id = try request.string("id")
      guard let workshopID = TelemetryWallpaper.workshopID(id),
        let steam = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(workshopID)")
      else { throw WebPanelRequest.invalid }
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title
        ?? workshop.workshopItem(id: id)?.title ?? ""
      let line = String(localized: "Plays on a Mac with WallpaperMachine: \(websiteURL.absoluteString)")
      let text = title.isEmpty ? line : "\(title)\n\(line)"
      share([text, steam], at: try anchor(request))
    case "shareApp":
      share([String(localized: "Wallpaper Engine wallpapers, now on macOS."), websiteURL], at: try anchor(request))
    case "starRepository":
      guard openSupportURL(AppUpdateConfiguration.repositoryURL) else {
        throw WallpaperActionError(message: String(localized: "The link could not be opened. Please try again."))
      }
      store.supportPrompt?.recordStarChosen()
    default:
      return false
    }
    return true
  }

  /// The website's home page in the panel's language.
  var websiteURL: URL {
    URL(string: language.hasPrefix("zh") ? "https://www.wallpapermachine.app/zh/" : "https://www.wallpapermachine.app/")!
  }

  /// The button's frame in the page, in CSS pixels from the top left of the web view.
  private func anchor(_ request: WebPanelRequest) throws -> NSRect {
    guard let rect = request.body["rect"] as? [String: Any] else { throw WebPanelRequest.invalid }
    let nested = WebPanelRequest(rect)
    let range = -100_000.0...100_000.0
    return NSRect(
      x: try nested.number("x", range: range), y: try nested.number("y", range: range),
      width: try nested.number("width", range: 0...100_000), height: try nested.number("height", range: 0...100_000))
  }

  private func share(_ items: [Any], at rect: NSRect) {
    if let presentSharePicker {
      presentSharePicker(items, rect)
      return
    }
    guard let webView else { return }
    // The page measures from its top. In a flipped view that is the view's own y, and the
    // edge below the button is maxY; otherwise both are mirrored.
    let flipped = webView.isFlipped
    let frame = flipped ? rect : NSRect(
      x: rect.minX, y: webView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    NSSharingServicePicker(items: items).show(relativeTo: frame, of: webView, preferredEdge: flipped ? .maxY : .minY)
  }
}
