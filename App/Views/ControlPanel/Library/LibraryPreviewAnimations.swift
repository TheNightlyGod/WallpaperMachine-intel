import Foundation
import Observation

/// Animation bytes observed by wallpaper ID, so a scrolling tile never invalidates its neighbours.
@MainActor
final class LibraryPreviewAnimations: Observable {
  private let registrar = ObservationRegistrar()
  private var values: [String: Data] = [:]

  subscript(id: String) -> Data? {
    get {
      registrar.access(self, keyPath: \.[id])
      return values[id]
    }
    set {
      registrar.withMutation(of: self, keyPath: \.[id]) {
        values[id] = newValue
      }
    }
  }

  // Scheduler bookkeeping is not a view dependency. Only reading an ID observes its bytes.
  var keys: Dictionary<String, Data>.Keys { values.keys }
  var isEmpty: Bool { values.isEmpty }

  func removeAll() {
    for id in Array(values.keys) { self[id] = nil }
  }
}
