import Foundation

/// The field names a request from the wallpaper service carries, and nothing it
/// carries in them.
///
/// The service's request types are private. Several decisions about them wait on
/// knowing whether a request always has a display, a size, a cache directory, or a
/// payload this extension does not read yet, and the only way to know is to look at a
/// request that really arrives. Reflection gives dotted field names such as
/// `destination.size.width`; the values (paths, titles, identifiers, sizes) are never
/// read into the result, so the line is safe to keep in `extension.log` and in the
/// diagnostics report.
enum LockScreenRequestShape {
  /// Dotted field names in `value`, sorted and without repeats.
  ///
  /// - Optionals are looked through, so a field's name is the same whether it is set.
  /// - An enum case that carries a payload is named by its case; a case without one
  ///   leaves only the name of the field it sits in.
  /// - A collection contributes `[]` and the fields of its first element. A set or a
  ///   dictionary contributes only its own name, because their elements and keys are
  ///   data.
  /// - Identifiers, URLs, dates and data blobs are leaves.
  /// - A name that is not a plain identifier (custom reflection can return any text)
  ///   is replaced by `?`.
  ///
  /// The walk goes level by level, so when `maxLabels` cuts it short the shallow names
  /// are the ones kept.
  static func labels(of value: Any, maxDepth: Int = 4, maxLabels: Int = 64) -> [String] {
    guard maxDepth > 0, maxLabels > 0 else { return [] }
    var found = Set<String>()
    var queue: [(value: Any, path: String, depth: Int)] = [(value, "", 0)]
    var next = 0
    while next < queue.count {
      let node = queue[next]
      next += 1
      guard node.depth < maxDepth, let current = unwrapped(node.value), !isLeaf(current)
      else { continue }
      for (label, child) in children(of: current) {
        let path = node.path.isEmpty ? label : node.path + "." + label
        guard found.count < maxLabels || found.contains(path) else { return found.sorted() }
        found.insert(path)
        queue.append((child, path, node.depth + 1))
      }
    }
    return found.sorted()
  }

  /// One log-sized line: the names separated by spaces, cut at a whole name with a count of
  /// those left out when they do not fit in `limit` characters.
  static func summary(_ labels: [String], limit: Int = 900) -> String {
    let joined = labels.joined(separator: " ")
    guard joined.count > limit else { return joined }
    var kept: [String] = []
    var length = 0
    for label in labels {
      let cost = label.count + (kept.isEmpty ? 0 : 1)
      guard length + cost <= max(0, limit - reserve) else { break }
      kept.append(label)
      length += cost
    }
    let omitted = labels.count - kept.count
    return (kept + ["…+\(omitted)"]).joined(separator: " ")
  }

  /// Room kept for the closing `…+N` of a cut summary.
  private static let reserve = 10

  private static func unwrapped(_ value: Any) -> Any? {
    var current = value
    while true {
      let mirror = Mirror(reflecting: current)
      guard mirror.displayStyle == .optional else { return current }
      guard let wrapped = mirror.children.first?.value else { return nil }
      current = wrapped
    }
  }

  private static func isLeaf(_ value: Any) -> Bool {
    value is UUID || value is URL || value is Date || value is Data
  }

  private static func children(of value: Any) -> [(label: String, value: Any)] {
    var mirror: Mirror? = Mirror(reflecting: value)
    switch mirror?.displayStyle {
    case .collection:
      return mirror?.children.first.map { [("[]", $0.value)] } ?? []
    case .set, .dictionary:
      return []
    default:
      var result: [(label: String, value: Any)] = []
      // Stored properties of the superclasses count; a class hierarchy is never this deep.
      var hops = 0
      while let level = mirror, hops < 8 {
        for child in level.children { result.append((name(child.label), child.value)) }
        mirror = level.superclassMirror
        hops += 1
      }
      return result
    }
  }

  /// `.0` becomes `0`; anything that is not a plain identifier becomes `?`.
  private static func name(_ label: String?) -> String {
    guard var label else { return "?" }
    if label.hasPrefix(".") { label.removeFirst() }
    let plain = !label.isEmpty && label.count <= 40
      && label.unicodeScalars.allSatisfy {
        ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
          || $0 == "_" || $0 == "$"
      }
    return plain ? label : "?"
  }
}
