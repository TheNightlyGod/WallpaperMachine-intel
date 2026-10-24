import AppKit
import Foundation

/// Every address the panel opens outside the app goes through here: Steam, GitHub, pixiv, Apple's
/// support pages and the licence text. A link built from remote data (a Workshop item, an author's
/// profile, a pixiv work) is only as trustworthy as the host it names, so `isAllowed` is the one
/// gate for `Link`, `openURL` and every button that opens one. Support-prompt links go through
/// their own injected opener and are not covered by it.
enum ExternalLink {
  /// Exact hosts, compared in lower case. A subdomain or a look-alike
  /// (`steamcommunity.com.example.net`) is not a match.
  static let allowedHosts: Set<String> = [
    "steamcommunity.com", "store.steampowered.com", "help.steampowered.com", "github.com",
    "www.gnu.org", "support.apple.com", "space.bilibili.com", "www.bilibili.com", "www.pixiv.net",
  ]

  /// Whether the panel may open `url`: https, a host on the list, and no user, password or port.
  static func isAllowed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else {
      return false
    }
    return allowedHosts.contains(url.host?.lowercased() ?? "")
  }

  /// `string` as a URL, or nil when it does not parse or is not allowed.
  static func allowed(_ string: String) -> URL? {
    guard let url = URL(string: string), isAllowed(url) else { return nil }
    return url
  }

  /// Opens `url` when it is allowed. `opener` is the seam tests replace so no browser opens.
  @MainActor @discardableResult
  static func open(_ url: URL, using opener: ((URL) -> Bool)? = nil) -> Bool {
    guard isAllowed(url) else { return false }
    return (opener ?? DesktopActions.current.open)(url)
  }

  // MARK: Fixed links

  /// Steam's mobile app, for approving a sign-in on a phone.
  static let steamMobileApp = URL(string: "https://store.steampowered.com/mobile")!
  /// Steam's help page for a Steam Guard code that arrives by email.
  static let steamEmailedCodeHelp = URL(
    string: "https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode")!
  static let steamJoin = URL(string: "https://store.steampowered.com/join/")!
  static let wallpaperEngineStore = URL(
    string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!
  /// Apple's page on how macOS treats apps it cannot verify.
  static let macOSAppSecurity = URL(string: "https://support.apple.com/en-us/102445")!
  static let gnuGPL3 = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

  // MARK: Built links

  /// The app's repository page.
  static var repository: URL { AppUpdateConfiguration.repositoryURL }
  /// The repository's issue list.
  static var repositoryIssues: URL { repository.appendingPathComponent("issues") }

  /// A wallpaper's page on the Steam Workshop. Nil unless `id` is a Workshop item id.
  static func workshopItem(id: String) -> URL? {
    guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
    return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
  }

  /// A work's page on pixiv. Nil unless `id` is a work id.
  static func pixivArtwork(id: String) -> URL? {
    guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
    return URL(string: "https://www.pixiv.net/artworks/\(id)")
  }

  /// GitHub's bug report form (`.github/ISSUE_TEMPLATE/bug_report.yml`) with `title` and what the
  /// app knows filled in. What the user did, saw and expected stay empty: the form requires the user
  /// to write them before it can be sent. Nothing is sent from here: the browser opens the draft and
  /// the user decides whether to submit it.
  static func newIssue(title: String, wallpaper: String, version: String, details: String) -> URL? {
    guard
      var components = URLComponents(
        url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
    else { return nil }
    // After `template` and `title`, each name is a field `id` in bug_report.yml: rename them together.
    components.queryItems = [
      URLQueryItem(name: "template", value: "bug_report.yml"), URLQueryItem(name: "title", value: title),
      URLQueryItem(name: "wallpaper", value: wallpaper), URLQueryItem(name: "version", value: version),
      URLQueryItem(name: "app-details", value: details),
    ]
    return components.url
  }

  /// Every fixed link above, for the test that holds them to the allowlist.
  static var fixedLinks: [URL] {
    [
      steamMobileApp, steamEmailedCodeHelp, steamJoin, wallpaperEngineStore, macOSAppSecurity,
      gnuGPL3, repository, repositoryIssues,
    ]
  }
}
