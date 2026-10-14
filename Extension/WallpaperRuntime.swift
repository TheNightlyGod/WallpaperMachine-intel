import AppKit
import IOSurface
import Security

/// All private ABI assumptions are checked against the loaded system classes.
/// No fallback offsets, process injection, or lock-screen window impersonation.
enum WallpaperRuntime {
  /// The extension's own container; holds only its shader cache.
  static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  /// Where the app publishes and this extension acknowledges; see
  /// `LockScreenConfiguration.exchangeDirectory`.
  static let exchange = LockScreenConfiguration.exchangeDirectory
  private static var handle: UnsafeMutableRawPointer?

  static func load() throws {
    if handle == nil {
      guard
        let framework = dlopen(
          "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
          RTLD_LAZY)
      else {
        throw failure("This macOS version does not provide WallpaperExtensionKit.")
      }
      handle = framework
    }
    for name in [
      "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperCreationRequestXPC",
      "WallpaperUpdateRequestXPC", "WallpaperIDXPC", "WallpaperSettingsViewModelsXPC",
    ] {
      guard NSClassFromString(name) != nil else {
        throw failure("Missing macOS wallpaper type: \(name)")
      }
    }
    _ = try storage(className: "WallpaperRemoteContextXPC", member: "box", count: 4)
    _ = try storage(
      className: "WallpaperSnapshotXPC", member: "rawValue",
      count: MemoryLayout<UnsafeRawPointer>.size)
  }

  static func failure(_ message: String.LocalizationValue) -> NSError {
    failure(detail: String(localized: message))
  }

  /// Text that is already final, such as the renderer's own error message.
  static func failure(detail: String) -> NSError {
    NSError(
      domain: "WallpaperMachine.LockScreen", code: 1,
      userInfo: [NSLocalizedDescriptionKey: detail])
  }

  private static func storage(className: String, member: String, count: Int) throws -> (
    AnyClass, Int
  ) {
    guard let cls = NSClassFromString(className), let ivar = class_getInstanceVariable(cls, member)
    else {
      throw failure("Unsupported macOS wallpaper layout: \(className).\(member)")
    }
    let offset = ivar_getOffset(ivar)
    guard offset == MemoryLayout<UnsafeRawPointer>.size,
      offset + count == class_getInstanceSize(cls)
        || (count == 4 && offset + 8 == class_getInstanceSize(cls))
    else {
      throw failure("Unsupported macOS wallpaper payload size: \(className)")
    }
    return (cls, offset)
  }

  static func contextReply(_ contextID: UInt32) throws -> AnyObject {
    let (cls, offset): (AnyClass, Int) = try storage(
      className: "WallpaperRemoteContextXPC", member: "box", count: 4)
    guard let raw = class_createInstance(cls, 0) else {
      throw failure("Cannot allocate wallpaper context reply.")
    }
    let object = raw as AnyObject
    Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(
      of: contextID, as: UInt32.self)
    return object
  }

  static func snapshotReply(_ surface: IOSurface) throws -> AnyObject {
    let (cls, offset): (AnyClass, Int) = try storage(
      className: "WallpaperSnapshotXPC", member: "rawValue",
      count: MemoryLayout<UnsafeRawPointer>.size)
    guard let raw = class_createInstance(cls, 0) else {
      throw failure("Cannot allocate wallpaper snapshot reply.")
    }
    let object = raw as AnyObject
    let retained = Unmanaged.passRetained(surface).toOpaque()
    Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(
      of: retained, as: UnsafeMutableRawPointer.self)
    return object
  }

  static func context(displayID: UInt32?) throws -> CAContext {
    guard let cls = NSClassFromString("CAContext"),
      class_getClassMethod(cls, NSSelectorFromString("remoteContextWithOptions:")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("contextId")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("setLayer:")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("invalidate")) != nil
    else {
      throw failure("Remote wallpaper composition is unavailable on this macOS version.")
    }
    let options: [String: Any] = displayID.map { ["displayId": $0] } ?? [:]
    guard
      let context = (cls as AnyObject).perform(
        NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue()
        as? CAContext,
      context.contextId != 0
    else { throw failure("macOS refused to create a remote wallpaper surface.") }
    return context
  }

  private static let onceLock = NSLock()
  private static var onceKeys = Set<String>()

  /// True the first time `key` is passed in this process; for logging one line per kind of event.
  static func firstTime(_ key: String) -> Bool {
    onceLock.lock()
    defer { onceLock.unlock() }
    return onceKeys.insert(key).inserted
  }

  /// Logs the field names of a request (never what they hold) the first time each distinct
  /// shape of `kind` arrives in this process. The request types are private, and a later
  /// decision about them needs to know what real requests carry; see
  /// `LockScreenRequestShape`.
  static func logRequestShape(_ kind: String, _ request: Any?) {
    guard let request else { return }
    // Deeper than the default: the system wraps the payload in one or two private layers.
    let labels = LockScreenRequestShape.labels(of: request, maxDepth: 6)
    guard firstTime("request-shape-\(kind)-" + labels.joined(separator: ",")) else { return }
    log(
      "Request shape \(kind): \(String(describing: type(of: request))) "
        + LockScreenRequestShape.summary(labels))
  }

  /// Compares the protocol this extension exports with the system's own declaration, once per
  /// process, and logs `XPC protocol matches the system` or `XPC protocol drift`. The check
  /// cannot change behavior: a system without the protocol or the runtime lookup is logged and
  /// skipped.
  static func verifyXPCProtocol(ours: Protocol) {
    guard firstTime("xpc-protocol-check") else { return }
    guard let system = objc_getProtocol("WallpaperExtensionKit.WallpaperExtensionXPCProtocol")
    else {
      log("XPC protocol check skipped: the system does not declare WallpaperExtensionXPCProtocol.")
      return
    }
    guard let theirs = LockScreenXPCDrift.encodings(of: system),
      let mine = LockScreenXPCDrift.encodings(of: ours)
    else {
      log("XPC protocol check skipped: the runtime does not report method type encodings.")
      return
    }
    let report = LockScreenXPCDrift.compare(ours: mine, system: theirs)
    if report.isClean {
      log("XPC protocol matches the system (\(theirs.count) selectors)")
    } else {
      log(
        "XPC protocol drift: missing=\(report.missing) extra=\(report.extra) "
          + "differing=\(report.differing)")
    }
  }

  /// Treat an unavailable audit token or signature lookup as an untrusted caller.
  static func accepts(_ connection: NSXPCConnection) -> Bool {
    guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
    var token = connection.auditToken
    let data = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code
    else { return false }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }

  static func field(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 8 else { return nil }
    let mirror = Mirror(reflecting: value)
    if let child = mirror.children.first(where: { $0.label == label }) { return child.value }
    for child in mirror.children {
      if let result = field(label, in: child.value, depth: depth + 1) { return result }
    }
    return nil
  }

  static func identifier(_ value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
      if let uuid = identifier(child.value, depth: depth + 1) { return uuid }
    }
    return nil
  }

  static func enumCase(_ value: Any) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
  }

  static func configuration() throws -> LockScreenConfiguration {
    do {
      return try LockScreenExtensionStatus.loadConfiguration(
        exchange: exchange, bundleURL: Bundle.main.bundleURL,
        reportWriteFailure: { log("Extension diagnostic failed: \($0.localizedDescription)") })
    } catch LockScreenExtensionStatus.ConfigurationError.unsupportedVersion(let version) {
      log("Configuration version=\(version), supported=\(LockScreenConfiguration.supportedVersion)")
      throw failure("Unsupported lock-screen configuration version.")
    }
  }

  static func asset(_ relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !components.contains(".."),
      !components.contains("."), !components.contains("")
    else {
      throw failure("Invalid lock-screen asset path.")
    }
    let root = exchange.resolvingSymlinksInPath().standardizedFileURL
    let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
      .standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"), FileManager.default.isReadableFile(atPath: url.path)
    else { throw failure("Lock-screen asset is unavailable: \(relativePath)") }
    return url
  }

  static func log(_ message: String) {
    NSLog("[MWE LockScreen] %@", message)
    // Small bounded local diagnostic, never asset contents or authentication data.
    let file = exchange.appendingPathComponent("extension.log")
    try? FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 {
      try? FileManager.default.removeItem(at: file)
    }
    let data = Data("\(Date()) \(message)\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
      try? data.write(to: file)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  }

  /// Earlier releases published into this container, which made macOS ask the app
  /// for access to another app's data on every launch. Only the extension may
  /// clean it up without that prompt; the shader cache stays.
  static func removeLegacyExchange() {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: documents.path) else { return }
    for name in names
    where name == LockScreenConfiguration.fileName || name == "extension.log"
      || name == "revisions" || (name.hasPrefix("ready-") && name.hasSuffix(".json"))
    {
      try? manager.removeItem(at: documents.appendingPathComponent(name))
    }
  }
}
