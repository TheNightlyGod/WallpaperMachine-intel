import Foundation

/// The notifications a wallpaper surface's drawing layer is asked for, and answers with, its
/// current frame. Posted with the layer as the object; the app's desktop poster, its switch hold
/// and the lock-screen extension ask, and the scene renderer
/// (`Renderer/Engine/src/Platform/Apple/SceneWallpaperBindings.mm`, which spells the same names
/// and keys), the web host and the video host answer. `DesktopPosterFrame` encodes and decodes
/// the answer's `userInfo`.
enum DesktopPosterNotification {
  static let request = Notification.Name("WallpaperMachine.requestDesktopPoster")
  static let ready = Notification.Name("WallpaperMachine.desktopPosterReady")

  /// The `userInfo` keys. A request carries only `context`; an answer carries the frame and the
  /// `context` of the request it answers.
  enum Key {
    static let pixels = "pixels"
    static let width = "width"
    static let height = "height"
    static let bgra = "bgra"
    static let context = "context"
  }

  /// The `context` a request or an answer carries, or nil when it carries none.
  static func context(in userInfo: [AnyHashable: Any]?) -> String? {
    userInfo?[Key.context] as? String
  }
}
