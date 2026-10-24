import Foundation
import Observation

struct WallpaperCompatibilityContext: Hashable, Sendable {
  enum Kind: String, Sendable { case scene, video, web, unknown }
  let wallpaperID: String
  let displayID: String
  let kind: Kind
  let supported: Bool
  let targetFPS: UInt32
  let targetAvailable: Bool
  let libraryRevision: UInt64
  let assetsConfiguration: String
}

struct WallpaperCompatibilityCheck: Equatable, Sendable {
  enum Status: String, Sendable { case ok, warning, unavailable, unknown }
  let id: String
  let status: Status
  let title: String
  let detail: String
}

/// Metadata-only preflight. Actor isolation keeps filesystem reads off the UI executor;
/// AVFoundation uses the same asynchronous admission rule as the production host.
actor WallpaperCompatibilityService {
  typealias Probe = @Sendable (URL) async -> NativeVideoProbeOutcome
  private let libraryURL: URL
  private let assetsURL: @Sendable () -> URL
  private let probe: Probe
  private struct CacheKey: Hashable {
    let context: WallpaperCompatibilityContext
    let content: [Stamp]
    let assets: [Stamp]
    let assetsPath: String
  }
  private struct Stamp: Hashable {
    let path: String
    let size: Int
    let modified: Date?
    let identity: String
  }
  private var cache: [CacheKey: [WallpaperCompatibilityCheck]] = [:]
  private var order: [CacheKey] = []
  private static let cacheLimit = 24
  private static let fileLimit = 20_000
  private static let manifestLimit = 2 * 1024 * 1024

  init(libraryURL: URL = ClientPaths.libraryURL,
       assetsURL: @escaping @Sendable () -> URL = { ClientPaths.assetsURL },
       probe: @escaping Probe = { await WallpaperCompatibilityService.playbackProbe(url: $0) }) {
    self.libraryURL = libraryURL
    self.assetsURL = assetsURL
    self.probe = probe
  }

  func check(_ context: WallpaperCompatibilityContext, retry: Bool = false) async
    -> [WallpaperCompatibilityCheck]
  {
    var checks: [WallpaperCompatibilityCheck] = []
    var cacheable = true
    func append(_ id: String, _ status: WallpaperCompatibilityCheck.Status,
                _ title: String, _ detail: String) {
      checks.append(.init(id: id, status: status, title: title, detail: detail))
    }
    append("target", context.targetAvailable ? .ok : .unavailable,
           String(localized: "Target display"), context.targetAvailable
           ? String(localized: "Checking this display at \(context.targetFPS) FPS, including its mirror group and global frame-rate cap.")
           : String(localized: "Choose a connected, enabled independent display. A mirror follows its source wallpaper."))
    append("lockScreen", context.kind == .web || context.kind == .unknown ? .unavailable : .warning,
           String(localized: "Lock screen"), context.kind == .web
           ? String(localized: "Web wallpapers are not supported on the lock screen.")
           : context.kind == .unknown
             ? String(localized: "This wallpaper type has no supported lock-screen route.")
             : String(localized: "Video and scene wallpapers have a lock-screen route. Publishing, resource access and extension playback still require runtime verification."))
    guard Self.validID(context.wallpaperID) else {
      append("project", .unavailable, String(localized: "Installed project"),
             String(localized: "The installed wallpaper identifier is not a safe library path."))
      return checks
    }
    let root = libraryURL.appendingPathComponent(context.wallpaperID, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let library = libraryURL.resolvingSymlinksInPath().standardizedFileURL
    guard Self.contains(root, in: library) else {
      append("project", .unavailable, String(localized: "Installed project"),
             String(localized: "The project resolves outside the installed library."))
      return checks
    }
    guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
      append("project", .unavailable, String(localized: "Installed project"),
             String(localized: "The installed wallpaper folder is missing or unreadable. Refresh or reinstall this wallpaper."))
      return checks
    }
    do {
      let content = try fingerprint(root)
      let shared = assetsURL().resolvingSymlinksInPath().standardizedFileURL
      let markers = ["shaders/genericimage2.vert", "shaders/genericimage2.frag",
                     "materials/util/effectpassthrough.json"]
      let assetStamps = context.kind == .scene ? markers.compactMap {
        try? stamp(shared.appendingPathComponent($0))
      } : []
      let key = CacheKey(context: context, content: content, assets: assetStamps, assetsPath: shared.path)
      if !retry, let found = cache[key] { return found }
      let manifest = root.appendingPathComponent("project.json")
      guard Self.readableRegular(manifest), let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= Self.manifestLimit,
            let project = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
            let entry = project["file"] as? String, !entry.isEmpty,
            !entry.hasPrefix("/"), !entry.contains("\0") else {
        append("project", .unavailable, String(localized: "Installed project"),
               String(localized: "project.json is missing, unreadable, too large or has no valid entry file. Reinstall this wallpaper."))
        return checks
      }
      guard (project["type"] as? String)?.lowercased() == context.kind.rawValue else {
        append("project", .unavailable, String(localized: "Installed project"),
               String(localized: "The manifest type no longer matches the library entry. Refresh your library before checking again."))
        return checks
      }
      let file = root.appendingPathComponent(entry).resolvingSymlinksInPath().standardizedFileURL
      guard Self.contains(file, in: root) else {
        append("entry", .unavailable, String(localized: "Entry resources"),
               String(localized: "The declared entry resolves outside this wallpaper folder."))
        return checks
      }
      append("project", context.supported ? .ok : .unavailable, String(localized: "Installed project"),
             context.supported ? String(localized: "The installed manifest has a declared entry file.")
             : String(localized: "The library reports this project type as unsupported."))
      let entryReadable = Self.readableRegular(file)
      let packedScene = context.kind == .scene && Self.readableRegular(root.appendingPathComponent("scene.pkg"))
      append("entry", entryReadable ? .ok : packedScene ? .unknown : .unavailable,
             String(localized: "Entry resources"), entryReadable
             ? String(localized: "The declared entry file is installed and readable. This does not verify every authored dependency.")
             : packedScene
               ? String(localized: "A scene package is installed. Its internal entry and dependencies need the renderer's package parser; preflight cannot certify them.")
               : String(localized: "The declared entry file is missing or unreadable. Reinstall this wallpaper."))
      switch context.kind {
      case .video:
        if entryReadable && context.targetAvailable && context.supported {
          let outcome = await probe(file)
          let refusal: NativeVideoRefusal?
          switch outcome {
          case .probed(let metadata): refusal = NativeVideoAdmission.decide(probe: metadata)
          case .refused(let failure): refusal = failure
          }
          cacheable = refusal?.isSettled ?? true
          append("nativeVideo", refusal == nil ? .ok : refusal?.isSettled == true ? .warning : .unknown,
                 String(localized: "Video playback"), refusal.map(\.reason)
                 ?? String(localized: "This video can be played, at its own frame rate. Actual player preparation and on-screen presentation are not verified by this check."))
        } else {
          append("nativeVideo", .unavailable, String(localized: "Video playback"),
                 String(localized: "Video playback needs a supported installed video, a readable entry and a valid target display."))
        }
      case .scene:
        let sharedReady = markers.allSatisfy { Self.readableRegular(shared.appendingPathComponent($0)) }
        append("sharedResources", sharedReady ? .ok : .unavailable,
               String(localized: "Shared scene resources"), sharedReady
               ? String(localized: "The required baseline shared shaders and material are installed. Authored resources are not fully validated.")
               : String(localized: "Baseline Wallpaper Engine shaders or materials are missing. Install or locate the complete scene assets folder."))
        append("sceneCapability", .unknown, String(localized: "Scene shader and graph support"),
               String(localized: "Preflight has no parsed render-graph capability result. Shader, puppet, particle and effect support need runtime evaluation; the live backend, and the reason a scene it cannot draw is held, are shown separately."))
      case .web:
        append("webRuntime", .unknown, String(localized: "Web runtime"),
               String(localized: "The entry file check does not execute scripts or verify media, local dependencies or WebGL. These need runtime evaluation."))
      case .unknown:
        append("capability", .unavailable, String(localized: "Wallpaper capability"),
               String(localized: "No supported renderer is declared for this wallpaper type."))
      }
      // Metadata may have loaded across an import/replacement. Never cache that answer.
      guard try fingerprint(root) == content,
            (context.kind != .scene || markers.compactMap({ try? stamp(shared.appendingPathComponent($0)) }) == assetStamps)
      else {
        return checks.filter { $0.id == "target" || $0.id == "lockScreen" } + [
          .init(id: "contentChanged", status: .unknown, title: String(localized: "Content changed"),
                detail: String(localized: "Wallpaper files changed during this check. Retry against the new content."))]
      }
      guard cacheable else { return checks }
      cache[key] = checks
      order.removeAll { $0 == key }
      order.append(key)
      while order.count > Self.cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
      return checks
    } catch {
      append("resources", .unknown, String(localized: "Installed resources"),
             String(localized: "The resource check could not complete: \(error.localizedDescription)"))
      return checks
    }
  }

  /// What the app's players say about the file: AVFoundation for most, the WebM reader for Matroska
  /// and WebM. Expressed as the admission probe the check already reads.
  static func playbackProbe(url: URL) async -> NativeVideoProbeOutcome {
    switch await VideoFormatSupport.inspect(url: url) {
    case .supported, .supportedWebM:
      return .probed(NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: true))
    case let .unsupported(format, reason):
      return .refused(.unsupportedFormat(VideoFormatSupport.message(for: format, reason: reason)))
    case let .unreadable(detail):
      return .refused(.preparationFailed(detail))
    }
  }

  private static func validID(_ id: String) -> Bool {
    !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains("\0")
  }
  private static func contains(_ file: URL, in root: URL) -> Bool { file.path.hasPrefix(root.path + "/") }
  private static func readableRegular(_ url: URL) -> Bool {
    guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          value.isRegularFile == true, (value.fileSize ?? 0) > 0 else { return false }
    return FileManager.default.isReadableFile(atPath: url.path)
  }
  private func stamp(_ url: URL) throws -> Stamp {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
    return Stamp(path: url.path, size: values.fileSize ?? 0, modified: values.contentModificationDate,
                 identity: values.fileResourceIdentifier.map { String(describing: $0) } ?? "")
  }
  private func fingerprint(_ root: URL) throws -> [Stamp] {
    var failure: Error?
    guard let walker = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
        errorHandler: { _, error in failure = error; return false }) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    var values = [try stamp(root)]
    var visited = 0
    for case let url as URL in walker {
      visited += 1
      guard visited <= Self.fileLimit else { throw CocoaError(.fileReadTooLarge) }
      let type = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if type.isSymbolicLink == true {
        // Do not follow external author references or bless an untracked target.
        throw CocoaError(.fileReadUnsupportedScheme)
      }
      if type.isRegularFile == true { values.append(try stamp(url)) }
    }
    if let failure { throw failure }
    return values.sorted { $0.path < $1.path }
  }
}

@MainActor @Observable
final class WallpaperCompatibilityStore {
  private(set) var context: WallpaperCompatibilityContext?
  private(set) var checking = false
  private(set) var checks: [WallpaperCompatibilityCheck] = []
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let service: WallpaperCompatibilityService
  @ObservationIgnored private var generation: UInt64 = 0

  init(service: WallpaperCompatibilityService = WallpaperCompatibilityService()) { self.service = service }

  /// Selection/config changes invalidate in-flight results without launching a probe.
  func select(_ value: WallpaperCompatibilityContext?) {
    guard context != value else { return }
    generation &+= 1
    context = value
    checking = false
    checks = []
  }

  func check(_ value: WallpaperCompatibilityContext, retry: Bool = false) async {
    select(value)
    generation &+= 1
    let ticket = generation
    checking = true
    checks = []
    onChange?()
    let result = await service.check(value, retry: retry)
    guard generation == ticket, context == value else { return }
    checks = result
    checking = false
    onChange?()
  }
}
