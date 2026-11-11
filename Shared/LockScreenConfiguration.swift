import CoreGraphics
import Foundation

/// The app publishes a complete immutable asset revision before replacing this file.
/// The extension never reads draft options or the app's private configuration files.
struct LockScreenConfiguration: Codable, Equatable {
  static let extensionIdentifier = "app.wallpapermachine.wallpaper-extension"
  static let changedNotification = "app.wallpapermachine.lock-screen.changed"
  static let fileName = "configuration.json"
  static let supportedVersion = 2
  /// Home-relative exchange directory. The app publishes here and the extension
  /// reads here and writes readiness and its log back. It lies outside both
  /// sandbox containers because macOS asks "would like to access data from other
  /// apps" on every launch when the app touches the extension's container.
  /// `Extension/WallpaperExtension.entitlements` must grant the same path.
  static let exchangeRelativePath = "Library/Application Support/WallpaperMachine/LockScreenExchange"
  /// Resolved against the account's real home: inside the sandbox `NSHomeDirectory()`
  /// names the container, and both processes must agree on one directory.
  static let exchangeDirectory: URL = {
    let home: URL
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
    }
    return home.appendingPathComponent(exchangeRelativePath, isDirectory: true)
  }()
  /// The private `com.apple.wallpaper` protocol the extension speaks has only been
  /// verified on macOS 26 and later; earlier releases keep the feature off.
  static var isSupportedBySystem: Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
  }

  var version: Int = supportedVersion
  var revision: String = UUID().uuidString
  var scenes: [LockScreenScene]
  var lockScreenEnabled: Bool = true
  var screenSaverEnabled: Bool = false
}

struct LockScreenScene: Codable, Equatable {
  var displayID: UInt32
  var title: String
  /// Paths relative to the exchange directory, never external URLs.
  var projectPath: String
  var assetsPath: String
  var previewPath: String?
  var fps: UInt32
  /// Native renderer values: none=0, stretch=1, fit=2, fill=3.
  var scalingMode: Int32
  var scalingFactor: Double
  var propertiesJSON: String?
  var paused: Bool
  /// A project-relative HTML entry; nil selects the scene/video renderer.
  var webEntryFile: String? = nil
  /// Where the picture sits in the room its display leaves around it. Absent from a
  /// configuration an older app wrote and for a web page, which fills its window; both
  /// read as centred, and a copy of the extension that predates the key ignores it.
  var framing: LockScreenFraming? = nil
  /// Whether this is a plain video wallpaper, which the extension plays with its own players (an
  /// AVFoundation layer, or the WebM player for WebM and Matroska) and never with the scene engine:
  /// a clip they cannot play is held and reported, as on the desktop. Absent for scenes and web
  /// pages, and from a configuration an older app wrote.
  var plainVideo: Bool? = nil
  /// The media file of a plain video wallpaper, relative to its project folder, present when the
  /// app found a regular file of that name inside the project. Absent for a video whose file is
  /// missing, which is held and reported, and for scenes and web pages.
  var nativeVideoFile: String? = nil
  /// A scene's script `localStorage` as it was when this revision was published: an
  /// exchange-relative folder holding `global.json` and `screen-<key>.json`, and the key of
  /// this display's file. The extension reads it and never writes (plan decision I3). Absent
  /// when the scene had saved nothing, for videos and web pages, and from older apps.
  var sceneStoragePath: String? = nil
  var sceneStorageScreenKey: String? = nil
  /// Wallpaper Engine's per-wallpaper options as saved (scenes and videos), the scene quality
  /// (scenes), a video's published image-filter file (exchange-relative) and its scheme-colour
  /// border as sRGB 0...1 (WE `sub_1400FFCB0`). Each is absent from older apps; a renderer is
  /// built with them, so a change of any of them replaces it.
  var engineOptions: WallpaperEngineOptions? = nil
  var sceneQuality: SceneQualitySettings? = nil
  var lutFile: String? = nil
  var borderColor: [Double]? = nil

  var effectiveFraming: LockScreenFraming { framing ?? .centered }

  /// The border colour as a layer takes it; nil (black) when absent or malformed.
  var borderCGColor: CGColor? {
    guard let rgb = borderColor, rgb.count == 3, rgb.allSatisfy({ $0.isFinite }) else { return nil }
    return CGColor(srgbRed: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1)
  }

  /// Whether a surface already showing `other` can take this scene without a new
  /// renderer. Frame rate, title and pause apply to the running renderer, and the
  /// preview path is not read by it. The scaling and the position are, like the
  /// project, only read when the renderer is built, so a change of either replaces it.
  /// So are the kind of wallpaper and the file a video plays.
  func sharesRenderer(with other: LockScreenScene) -> Bool {
    projectPath == other.projectPath && assetsPath == other.assetsPath
      && webEntryFile == other.webEntryFile && propertiesJSON == other.propertiesJSON
      && scalingMode == other.scalingMode && scalingFactor == other.scalingFactor
      && effectiveFraming == other.effectiveFraming
      && plainVideo == other.plainVideo && nativeVideoFile == other.nativeVideoFile
      && sceneStoragePath == other.sceneStoragePath
      && sceneStorageScreenKey == other.sceneStorageScreenKey
      && engineOptions == other.engineOptions && sceneQuality == other.sceneQuality
      && lutFile == other.lutFile && borderColor == other.borderColor
  }
}

/// A position as fractions of the room around the picture on each axis: 0 is the left
/// or top edge, 1 the right or bottom edge and 0.5 on both the centred layout every
/// wallpaper has until it is moved. The renderer clamps what it is given, so
/// `isValid` is what keeps a hand-edited or corrupt file from being drawn silently
/// somewhere else.
struct LockScreenFraming: Codable, Equatable {
  static let centered = LockScreenFraming(panX: 0.5, panY: 0.5)

  var panX: Double = 0.5
  var panY: Double = 0.5

  var isValid: Bool {
    (0.0...1.0).contains(panX) && (0.0...1.0).contains(panY)
  }
}

/// Written once a non-preview surface has GPU-ready pixels, or with `error` when
/// acquiring or replacing its renderer failed; never optimistically.
///
/// `held` is the other way a surface can be ready without drawing: Native Metal could not draw the scene
/// (or the extension's players could not play the video), so it shows its last frame or the project's
/// preview picture and says why, in words the extension has already localized. It is not an `error`: the surface exists and
/// shows a picture, and the app keeps the lock screen on it and shows the note. A file an older
/// extension wrote has no such key and reads as nil.
struct LockScreenReadiness: Codable {
  var revision: String
  var displayID: UInt32
  var error: String?
  var held: String? = nil
  /// The extension process that wrote it, so the app can tell when that renderer is gone.
  /// Absent from copies that predate it.
  var processID: Int32? = nil
}

/// An empty file the extension leaves in the exchange directory once macOS has closed every
/// connection to its process, and removes when a host connects again. macOS ends such a process
/// while the Mac is unlocked, live surfaces and all; that ending is not the renderer failing.
/// A copy of the extension that predates it never leaves one.
enum LockScreenHostRelease {
  static func fileName(processID: Int32) -> String { "released-\(processID)" }
  static let prefix = "released-"
}
