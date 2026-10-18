import AppKit
import ApplicationServices
import XCTest

/// One element of the accessibility tree of hosted content, as VoiceOver reads it: for the render
/// tests that check what a control is called, what it hints and what a list row says.
///
/// SwiftUI's own elements answer the informal accessibility protocol and do not cast to
/// `NSAccessibilityProtocol`, so every attribute is read through key-value coding. The tree is only
/// as complete as offscreen hosting makes it: the rows of a list hang off their cells, and the
/// content of a `ScrollView` exposes only its AppKit controls, so a test hosts a page directly when
/// it needs the page's own elements.
@MainActor
struct AccessibilityElement {
  let object: NSObject

  var role: String { string("accessibilityRole") }
  var label: String { string("accessibilityLabel") }
  var value: String { string("accessibilityValue") }
  var help: String { string("accessibilityHelp") }
  var identifier: String { string("accessibilityIdentifier") }
  /// What it says: its label, or, for a text, its value.
  var text: String { label.isEmpty ? value : label }

  var children: [AccessibilityElement] {
    ((attribute("accessibilityChildren") as? [Any]) ?? []).compactMap {
      ($0 as? NSObject).map(AccessibilityElement.init)
    }
  }

  /// The element and everything under it, each once and at most `limit` of them: the tree can
  /// lead back to an element already visited.
  func all(limit: Int = 4_000) -> [AccessibilityElement] {
    var seen = Set<ObjectIdentifier>()
    var found: [AccessibilityElement] = []
    func visit(_ element: AccessibilityElement, depth: Int) {
      guard depth < 40, found.count < limit, seen.insert(ObjectIdentifier(element.object)).inserted
      else { return }
      found.append(element)
      for child in element.children { visit(child, depth: depth + 1) }
    }
    visit(self, depth: 0)
    return found
  }

  /// The first element at or under this one with `identifier`.
  func first(identifier: String) -> AccessibilityElement? {
    all().first { $0.identifier == identifier }
  }

  /// The first element at or under this one with `role` ("AXCheckBox", "AXSlider").
  func first(role: String) -> AccessibilityElement? {
    all().first { $0.role == role }
  }

  /// Every element reachable from `view` or from any view inside it, each once. A list's rows are
  /// reached through their cells, which the root of the tree does not list.
  static func everything(in view: NSView) -> [AccessibilityElement] {
    var seen = Set<ObjectIdentifier>()
    var found: [AccessibilityElement] = []
    func walk(_ view: NSView) {
      for element in AccessibilityElement(object: view).all()
      where seen.insert(ObjectIdentifier(element.object)).inserted {
        found.append(element)
      }
      view.subviews.forEach(walk)
    }
    walk(view)
    return found
  }

  private func attribute(_ key: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key)
  }

  private func string(_ key: String) -> String {
    switch attribute(key) {
    case let text as String: text
    case let text as NSAttributedString: text.string
    case let number as NSNumber: number.stringValue
    default: ""
    }
  }
}

/// Makes the test host look, to SwiftUI, like an app an accessibility client is talking to.
///
/// On macOS 26 SwiftUI builds no accessibility elements for hosted content until a client such as
/// VoiceOver has asked the app something; macOS 27 builds them regardless. The render tests read
/// that tree, so on a Mac with no client running (a hosted CI runner) every page looked empty.
/// One request to this app's own element, sent the way a client sends it, is enough; it is made
/// off the main thread because the app answers it there.
enum AccessibilityClient {
  @MainActor private static var connected: Task<Void, Never>?

  @MainActor static func connect() async {
    if connected == nil {
      let pid = getpid()
      connected = Task.detached {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
        // Both answer "unsupported" from AppKit; the requests themselves are what count.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
      }
    }
    await connected?.value
  }
}

enum PanelTestSupport {
  /// Skips a test of how the system draws or drives an unshown window where macOS 26 does it
  /// differently from macOS 27 and the difference cannot be observed without a desktop. The
  /// behaviour on macOS 26 is then unverified, not passed: check it there by hand.
  static func skipBeforeMacOS27(_ reason: String) throws {
    let current = ProcessInfo.processInfo.operatingSystemVersion
    if current.majorVersion < 27 { throw XCTSkip("\(reason) (macOS \(current.majorVersion))") }
  }
}
