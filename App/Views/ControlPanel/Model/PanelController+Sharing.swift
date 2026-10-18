import Foundation

/// What the system share menu is handed: one link and the words that go with it.
struct SharePayload: Equatable, Sendable {
  var url: URL
  /// The subject line services that take one use (Mail), or empty.
  var subject: String
  var message: String
}

/// Sharing a wallpaper or the app, and the About star link. Every link is built here from fixed
/// parts and a Workshop id, so nothing a wallpaper or Steam says becomes a URL.
extension PanelController {
  /// The website's home page in the panel's language (the Chinese page for either Chinese).
  var websiteURL: URL {
    URL(
      string: appLanguage.effective.tag.hasPrefix("zh")
        ? "https://www.wallpapermachine.app/zh/" : "https://www.wallpapermachine.app/")!
  }

  /// A Workshop wallpaper, installed or on Discover: its Workshop page, with its title and the
  /// website in the message. Nil for anything without a Workshop page (imports, pixiv saves,
  /// pictures), which then offers no Share.
  func wallpaperShare(_ id: String) -> SharePayload? {
    guard let workshopID = TelemetryWallpaper.workshopID(id),
      let steam = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(workshopID)")
    else { return nil }
    let title =
      store.librarySnapshot.wallpapers.first { $0.id == id }?.title
      ?? workshop.workshopItem(id: id)?.title ?? ""
    let line = L("Plays on a Mac with WallpaperMachine: \(websiteURL.absoluteString)")
    return SharePayload(
      url: steam, subject: title, message: title.isEmpty ? line : "\(title)\n\(line)")
  }

  /// **Share WallpaperMachine…** in Settings › About.
  var appShare: SharePayload {
    SharePayload(
      url: websiteURL, subject: "WallpaperMachine",
      message: L("Wallpaper Engine wallpapers, now on macOS."))
  }

  /// **Star on GitHub** in Settings › About: the repository, which also answers the star prompt.
  func starRepository() async throws {
    guard openSupportURL(AppUpdateConfiguration.repositoryURL) else {
      throw WallpaperActionError(message: L("The link could not be opened. Please try again."))
    }
    store.supportPrompt?.recordStarChosen()
  }
}
