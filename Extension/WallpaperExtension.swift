import AppKit
import ExtensionFoundation

private final class WallpaperHandler: NSObject, WallpaperExtensionXPCProtocol {
  /// Counts what this connection carries, for the line logged when it closes.
  private let trace: LockScreenConnectionTrace

  init(trace: LockScreenConnectionTrace) {
    self.trace = trace
    super.init()
  }

  /// Every request the system sends comes through here. One this extension has nothing to do
  /// for (`inert`) is answered with an empty result, and the first of each kind is logged so a
  /// request that macOS starts sending shows up in `extension.log`.
  private func serve<Result>(
    _ selector: String, inert: Bool = false, _ body: () -> Result
  ) -> Result {
    trace.noteServed()
    if inert, WallpaperRuntime.firstTime("inert-\(selector)") {
      WallpaperRuntime.log("Unsupported request \(selector) answered inertly")
    }
    return body()
  }

  func acquire(withId identifier: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    serve("acquireWithId:request:reply:") {
      DispatchQueue.main.async {
        WallpaperController.shared.acquire(id: identifier, request: request, reply: reply)
      }
    }
  }
  func update(withId identifier: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
    serve("updateWithId:request:reply:") {
      DispatchQueue.main.async {
        do {
          try WallpaperController.shared.update(id: identifier, request: request)
          reply(nil)
        } catch { reply(error) }
      }
    }
  }
  func invalidate(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
    serve("invalidateWithId:reply:") {
      DispatchQueue.main.async {
        WallpaperController.shared.invalidate(id: identifier)
        reply(nil)
      }
    }
  }
  func snapshot(withId identifier: Any?, reply: @escaping (Any?, Error?) -> Void) {
    serve("snapshotWithId:reply:") {
      DispatchQueue.main.async { WallpaperController.shared.snapshot(id: identifier, reply: reply) }
    }
  }
  func provideSettingsViewModels(
    withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void
  ) {
    serve("provideSettingsViewModelsWithContentTypes:reply:") {
      do { reply(try WallpaperSettingsProvider.response(), nil) } catch {
        reply(nil, error)
        WallpaperRuntime.log("Settings unavailable: \(error.localizedDescription)")
      }
    }
  }
  func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (Any?, Error?) -> Void) {
    serve("isChoiceDownloadedWith:reply:") {
      // The provider is installed locally; its manifest can still report no applied scene.
      // macOS 27 declares an NSNumber reply, and any other reply type drops the connection.
      reply(NSNumber(value: true), nil)
    }
  }
  func selectedChoicesDidChange(for identifier: Any?, reply: @escaping (Error?) -> Void) {
    serve("selectedChoicesDidChangeFor:reply:") {
      DispatchQueue.main.async {
        WallpaperController.shared.reload()
        reply(nil)
      }
    }
  }
  func handleNotification(withNamed name: String?, reply: @escaping (Error?) -> Void) {
    serve("handleNotificationWithNamed:reply:") {
      // Answered first: the agent handles its requests one at a time.
      reply(nil)
      guard let name else { return }
      DispatchQueue.main.async { WallpaperController.shared.hostNotification(named: name) }
    }
  }

  // The rest of the system's protocol. WallpaperMachine offers one provider-wide choice that is
  // always installed, takes no downloads, shuffle, context menu items or added wallpapers, and
  // has no earlier version to migrate from, so each request has the answer "nothing to do".
  func migrateSelectedChoice(for choiceID: Any?, reply: @escaping (Any?, Error?) -> Void) {
    serve("migrateSelectedChoiceFor:reply:", inert: true) { reply(choiceID, nil) }
  }
  func migrate(from: Any?, to: Any?, reply: @escaping (Error?) -> Void) {
    serve("migrateFrom:to:reply:", inert: true) { reply(nil) }
  }
  func addChoiceRequest(
    withChoiceRequest choiceRequest: Any?, onBehalfOfProcess process: Any?,
    reply: @escaping (Any?, Error?) -> Void
  ) {
    serve("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", inert: true) {
      reply(nil, WallpaperRuntime.failure("WallpaperMachine does not accept added wallpapers."))
    }
  }
  func removeChoiceRequest(withChoiceRequest choiceRequest: Any?, reply: @escaping (Error?) -> Void) {
    serve("removeChoiceRequestWithChoiceRequest:reply:", inert: true) { reply(nil) }
  }
  func canSkipShuffledContent(withId identifier: Any?, reply: @escaping (Bool, Error?) -> Void) {
    serve("canSkipShuffledContentWithId:reply:", inert: true) { reply(false, nil) }
  }
  func skipShuffledContent(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
    serve("skipShuffledContentWithId:reply:", inert: true) { reply(nil) }
  }
  func download(withChoiceID choiceID: Any?, reply: @escaping (Error?) -> Void) -> Progress {
    serve("downloadWithChoiceID:reply:", inert: true) {
      // Nothing downloads, so the progress handed back is already complete.
      let progress = Progress(totalUnitCount: 1)
      progress.completedUnitCount = 1
      reply(nil)
      return progress
    }
  }
  func cancelDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
    serve("cancelDownloadFor:reply:", inert: true) { reply(nil) }
  }
  func pauseDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
    serve("pauseDownloadFor:reply:", inert: true) { reply(nil) }
  }
  func resumeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
    serve("resumeDownloadFor:reply:", inert: true) { reply(nil) }
  }
  func removeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
    serve("removeDownloadFor:reply:", inert: true) { reply(nil) }
  }
  func invokeContextMenuAction(
    withMenuItemID itemID: String?, groupItemID: String?, reply: @escaping (Error?) -> Void
  ) {
    serve("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", inert: true) { reply(nil) }
  }
  func handleDebugRequest(for request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    serve("handleDebugRequestFor:reply:", inert: true) {
      reply(nil, WallpaperRuntime.failure("WallpaperMachine does not handle debug requests."))
    }
  }
}

private struct NativeWallpaperConfiguration: AppExtensionConfiguration {
  func accept(connection: NSXPCConnection) -> Bool {
    guard LockScreenConfiguration.isSupportedBySystem else {
      WallpaperRuntime.log("Rejected wallpaper host: this macOS release is not supported.")
      return false
    }
    guard WallpaperRuntime.accepts(connection) else {
      WallpaperRuntime.log("Rejected untrusted wallpaper host.")
      return false
    }
    do { try WallpaperRuntime.load() } catch {
      WallpaperRuntime.log(error.localizedDescription)
      return false
    }
    let interface = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
    let names = [
      "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
      "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
      "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperSettingsViewModelsXPC",
      "WallpaperExtensionChoiceRequestXPC", "AuditTokenXPC", "WallpaperDebugRequestXPC",
      "WallpaperMigrationVersionXPC",
    ]
    let classes =
      NSSet(
        array: names.compactMap(NSClassFromString) + [
          NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self,
          NSError.self,
        ]) as! Set<AnyHashable>
    for (selector, indexes, reply) in [
      ("acquireWithId:request:reply:", [0, 1], false), ("acquireWithId:request:reply:", [0], true),
      ("updateWithId:request:reply:", [0, 1], false), ("invalidateWithId:reply:", [0], false),
      ("snapshotWithId:reply:", [0], false), ("snapshotWithId:reply:", [0], true),
      ("provideSettingsViewModelsWithContentTypes:reply:", [0], false),
      ("provideSettingsViewModelsWithContentTypes:reply:", [0], true),
      ("isChoiceDownloadedWith:reply:", [0], false),
      ("selectedChoicesDidChangeFor:reply:", [0], false),
      ("migrateSelectedChoiceFor:reply:", [0], false),
      ("migrateSelectedChoiceFor:reply:", [0], true),
      ("migrateFrom:to:reply:", [0, 1], false),
      ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", [0, 1], false),
      ("removeChoiceRequestWithChoiceRequest:reply:", [0], false),
      ("canSkipShuffledContentWithId:reply:", [0], false),
      ("skipShuffledContentWithId:reply:", [0], false),
      ("downloadWithChoiceID:reply:", [0], false),
      ("cancelDownloadFor:reply:", [0], false), ("pauseDownloadFor:reply:", [0], false),
      ("resumeDownloadFor:reply:", [0], false), ("removeDownloadFor:reply:", [0], false),
      ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", [0, 1], false),
      ("handleDebugRequestFor:reply:", [0], false),
      ("handleNotificationWithNamed:reply:", [0], false),
    ] {
      for index in indexes {
        interface.setClasses(
          classes, for: NSSelectorFromString(selector), argumentIndex: index, ofReply: reply)
      }
    }
    WallpaperRuntime.verifyXPCProtocol(ours: interface.protocol)
    connection.exportedInterface = interface
    let trace = LockScreenConnectionTrace()
    connection.exportedObject = WallpaperHandler(trace: trace)
    // Surface lifetime is owned by WallpaperID, not transient settings/thumbnail connections.
    // Counted before the connection resumes, so a pending idle exit cannot end
    // the process under it; the close always follows on the main queue.
    WallpaperController.idleExit.connectionOpened()
    let pid = connection.processIdentifier
    connection.invalidationHandler = {
      DispatchQueue.main.async {
        WallpaperController.idleExit.connectionClosed()
        // served=0 is a connection that opened and closed without asking for anything.
        WallpaperRuntime.log(
          "Connection closed pid=\(pid) served=\(trace.served) "
            + "open=\(WallpaperController.idleExit.openConnections) "
            + "surfaces=\(WallpaperController.shared.surfaceCount)")
      }
    }
    connection.resume()
    WallpaperRuntime.log("Accepted native host pid=\(connection.processIdentifier)")
    return true
  }
}

@main
final class WallpaperMachineExtension: NSObject, AppExtension {
  override required init() {
    super.init()
    do {
      try WallpaperRuntime.load()
      DispatchQueue.main.async { WallpaperController.shared.start() }
      WallpaperRuntime.log(
        "Native wallpaper extension started: bundle=\(Bundle.main.bundleURL.path) configurationVersion=\(LockScreenConfiguration.supportedVersion)")
    } catch { WallpaperRuntime.log("Unavailable: \(error.localizedDescription)") }
  }
  var configuration: some AppExtensionConfiguration { NativeWallpaperConfiguration() }
}
