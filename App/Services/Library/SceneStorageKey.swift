import AppKit
import Foundation

/// The name of a display's script `localStorage` screen file (plan decision I3), the same rule
/// as the renderer bridge's `DisplayIdentity::storage_key`: `uuid-<UUID>`, else
/// `edid-<vendor>-<model>-<serial>`, else `display-<id>`, using only `[A-Za-z0-9-]`.
enum SceneStorageKey {
  static func screenKey(
    uuid: String?, vendor: UInt32? = nil, model: UInt32? = nil, serial: UInt32? = nil,
    displayID: UInt32
  ) -> String {
    let safe = uuid.map { text in
      String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        .map(Character.init))
    }
    if let safe, !safe.isEmpty { return "uuid-\(safe)" }
    if let vendor, let model, let serial { return "edid-\(vendor)-\(model)-\(serial)" }
    return "display-\(displayID)"
  }

  /// The key of an attached display, read from CoreGraphics.
  static func screenKey(displayID: CGDirectDisplayID) -> String {
    let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)
      .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    let serial = CGDisplaySerialNumber(displayID)
    let vendor = CGDisplayVendorNumber(displayID)
    let model = CGDisplayModelNumber(displayID)
    return screenKey(
      uuid: uuid, vendor: vendor == 0 ? nil : vendor, model: model == 0 ? nil : model,
      serial: serial == 0 ? nil : serial, displayID: displayID)
  }
}
