import Foundation

/// One frame of a wallpaper surface as `DesktopPosterNotification.ready` carries it: 8-bit pixels,
/// four bytes each, BGRA or RGBA.
struct DesktopPosterFrame: Sendable {
  var pixels: Data
  var width: Int
  var height: Int
  var bgra: Bool
}

extension DesktopPosterFrame {
  /// The frame a `DesktopPosterNotification.ready` carries, or nil when any of its four
  /// values is missing or of another type. An extension, so the memberwise initializer stays.
  init?(userInfo: [AnyHashable: Any]?) {
    typealias Key = DesktopPosterNotification.Key
    guard let values = userInfo,
      let pixels = values[Key.pixels] as? Data,
      let width = values[Key.width] as? Int, let height = values[Key.height] as? Int,
      let bgra = values[Key.bgra] as? Bool
    else { return nil }
    self.init(pixels: pixels, width: width, height: height, bgra: bgra)
  }

  /// The `userInfo` of a `DesktopPosterNotification.ready` answering a request made with `context`.
  func userInfo(context: String?) -> [AnyHashable: Any] {
    typealias Key = DesktopPosterNotification.Key
    return [
      Key.pixels: pixels, Key.width: width, Key.height: height, Key.bgra: bgra, Key.context: context ?? "",
    ]
  }
}
