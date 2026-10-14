import Foundation
import ObjectiveC

/// Compares the extension's XPC protocol with the system's own declaration of it. A selector the
/// wallpaper service sends that the exported interface lacks, or a reply of another type, makes
/// macOS invalidate the connection, so a difference after a system update is worth a log line.
enum LockScreenXPCDrift {
  struct Report: Equatable {
    /// Selectors the system declares and the extension does not.
    var missing: [String]
    /// Selectors the extension declares and the system does not.
    var extra: [String]
    /// Selectors both declare with different argument or reply types.
    var differing: [String]

    var isClean: Bool { missing.isEmpty && extra.isEmpty && differing.isEmpty }
  }

  /// Drops the quoted class names, which one side's declaration may carry and the other's omit
  /// (`id` against a named class), and keeps type codes, offsets and block signatures: a
  /// `BOOL` reply and an `NSNumber` reply stay different.
  static func normalized(_ encoding: String) -> String {
    var result = ""
    var quoted = false
    for character in encoding {
      if character == "\"" {
        quoted.toggle()
      } else if !quoted {
        result.append(character)
      }
    }
    return result
  }

  static func compare(ours: [String: String], system: [String: String]) -> Report {
    Report(
      missing: system.keys.filter { ours[$0] == nil }.sorted(),
      extra: ours.keys.filter { system[$0] == nil }.sorted(),
      differing: ours.keys.filter { selector in
        guard let theirs = system[selector] else { return false }
        return normalized(theirs) != normalized(ours[selector]!)
      }.sorted())
  }

  /// Selector to extended type encoding for every method `proto` declares itself. Nil when the
  /// runtime cannot return extended encodings, in which case a comparison would only see
  /// argument counts and miss a reply-type difference.
  static func encodings(of proto: Protocol) -> [String: String]? {
    guard let lookup = methodTypeEncoding else { return nil }
    var table: [String: String] = [:]
    for required in [true, false] {
      var count: UInt32 = 0
      guard let list = protocol_copyMethodDescriptionList(proto, required, true, &count) else {
        continue
      }
      defer { free(list) }
      for index in 0..<Int(count) {
        guard let selector = list[index].name, let encoding = lookup(proto, selector, required, true)
        else { return nil }
        table[NSStringFromSelector(selector)] = String(cString: encoding)
      }
    }
    return table
  }

  private typealias MethodTypeEncoding =
    @convention(c) (Protocol, Selector, Bool, Bool) -> UnsafePointer<CChar>?

  /// libobjc exports this without a header. Looked up rather than linked, so a system that
  /// stops exporting it disables the check instead of keeping the extension from loading.
  private static let methodTypeEncoding: MethodTypeEncoding? = {
    // RTLD_DEFAULT searches every image already loaded into the process.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_protocol_getMethodTypeEncoding")
    else { return nil }
    return unsafeBitCast(symbol, to: MethodTypeEncoding.self)
  }()
}
