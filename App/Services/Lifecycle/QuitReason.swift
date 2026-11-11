import AppKit
import CoreServices
import Foundation

/// Who or what asked the app to quit.
///
/// The answer is logged with every quit and kept in the session ledger, so a report
/// about a lost wallpaper or a slow quit says whether the user chose Quit, an update
/// replaced the app, or the system was logging out, restarting or shutting down.
enum QuitReason: String, Codable, CaseIterable, Sendable {
    /// Quit from the menu, the Dock or another app's Apple event, with nothing else pending.
    case user
    /// An update installer is waiting for the app to quit.
    case update
    case logout
    case restart
    case shutdown
    /// A termination signal (SIGTERM, SIGHUP) was turned into a quit.
    case signal
    /// An Apple event named a reason this build does not know.
    case unknown

    /// Picks the reason from everything known when `applicationShouldTerminate` runs.
    ///
    /// The order is: a signal, then the system leaving (the Apple event's own reason
    /// first, the power-off notification when the event names none), then an update,
    /// then a reason the build does not know, and a plain quit last. Pure, so every
    /// combination is exercised without a logout.
    static func classify(
        appleEventReason: UInt32?,
        powerOffNotified: Bool,
        updateInstallPending: Bool,
        terminationSignal: Int32?
    ) -> QuitReason {
        if terminationSignal != nil { return .signal }
        if let appleEventReason, let kind = powerOffKind(forCode: appleEventReason) { return kind }
        // The notification does not say which of the three it is; `shutdown` is the
        // general case, and the log line also carries the raw event reason.
        if powerOffNotified { return .shutdown }
        if updateInstallPending { return .update }
        if let appleEventReason, appleEventReason != UInt32(kAEQuitAll) { return .unknown }
        return .user
    }

    /// The system is logging out, restarting or shutting down.
    var isPowerOff: Bool {
        switch self {
        case .logout, .restart, .shutdown: true
        case .user, .update, .signal, .unknown: false
        }
    }

    /// The reason as the session ledger keeps it. A quit that a signal asked for names the
    /// signal, because `signal` alone does not say whether it was a kill or a closing terminal.
    static func ledgerReason(for reason: QuitReason, signal: Int32? = nil) -> String {
        guard reason == .signal, let signal else { return reason.rawValue }
        return "terminated by " + TerminationSignalRelay.name(of: signal)
    }

    /// What the session ledger keeps as the reason of a quit that did not go to plan, so
    /// the next launch's `previous session:` line says what was left undone. A quit that
    /// went to plan keeps the plain reason.
    static func ledgerText(
        for reason: QuitReason, signal: Int32? = nil, desktopUnrestored: Bool, stalled: [String]
    ) -> String {
        var text = ledgerReason(for: reason, signal: signal)
        if desktopUnrestored { text += "; desktop restoration unfinished" }
        if !stalled.isEmpty { text += "; left running: " + stalled.joined(separator: ", ") }
        return text
    }

    private static func powerOffKind(forCode code: UInt32) -> QuitReason? {
        switch code {
        case UInt32(kAEReallyLogOut), UInt32(kAELogOut): .logout
        case UInt32(kAERestart), UInt32(kAEShowRestartDialog): .restart
        case UInt32(kAEShutDown), UInt32(kAEShowShutdownDialog): .shutdown
        default: nil
        }
    }

    /// The reason in a quit event (`why?`), or `nil` when the event names none.
    ///
    /// It is an event parameter, not an attribute, and `currentAppleEvent` is valid only
    /// while the event is being handled, so call this synchronously inside
    /// `applicationShouldTerminate`. A parameter that is not an enumerated code is ignored.
    static func appleEventReason(from event: NSAppleEventDescriptor?) -> UInt32? {
        guard let parameter = event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)),
              parameter.descriptorType == DescType(typeEnumerated) else { return nil }
        return parameter.enumCodeValue
    }

    /// A four-character code as it reads in the headers (`'rlgo'`), for the log.
    static func text(forCode code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return String(format: "0x%08X", code) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

/// Who asked for a quit, for the log line: the app's own Quit or Exit, or the process that
/// sent the quit Apple event (the Dock, loginwindow, another app, a script).
///
/// `QuitReason.user` covers all of them, so without this a quit another program sent reads
/// the same as one the user chose.
enum QuitRequester: Equatable, Sendable {
    /// The app's own Quit or Exit menu item. AppKit hands a menu choice no Apple event.
    case menu
    /// The process that sent the quit Apple event.
    case process(pid_t)
    /// Neither: a signal, the updater, or an event that does not name its sender.
    case none

    /// An event's sender beats the menu flag: a menu choice never arrives as an event.
    static func resolve(menuChosen: Bool, senderPID: pid_t?) -> QuitRequester {
        if let senderPID { return .process(senderPID) }
        return menuChosen ? .menu : .none
    }

    /// The pid of the process that sent `event`. The Apple Event Manager sets it on an event
    /// it delivers, never on one built in place. Like `QuitReason.appleEventReason(from:)`,
    /// call this synchronously inside `applicationShouldTerminate`, while the event is handled.
    static func senderPID(of event: NSAppleEventDescriptor?) -> pid_t? {
        guard let pid = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid > 0 else { return nil }
        return pid
    }

    /// The requester as the log shows it. A process is named by its bundle identifier, or
    /// by its program's file name (never the full path, which can hold the user's name).
    func logText(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        name: (pid_t) -> String? = QuitRequester.processName
    ) -> String {
        switch self {
        case .menu: "menu"
        case .none: "none"
        case .process(let pid) where pid == ownPID: "self"
        case .process(let pid): "\(name(pid) ?? "exited") (pid \(pid))"
        }
    }

    static func processName(_ pid: pid_t) -> String? {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return bundleID }
        return InstanceHandOff.executablePath(ofProcess: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// Remembers that macOS announced a logout, restart or shutdown.
///
/// The announcement stands in for a quit event that names no reason. Nothing tells the
/// app when another app refuses the logout, so a notice counts only for a while: after
/// that a plain Quit is the user's.
struct PowerOffNotice {
    /// How long an announcement is believed. A judgment, not a measured value: long
    /// enough for the system to reach this app, short enough that a refused logout
    /// does not relabel the next Quit.
    static let lifetime: Duration = .seconds(120)

    private var postedAt: ContinuousClock.Instant?

    mutating func record(at instant: ContinuousClock.Instant = .now) {
        postedAt = instant
    }

    /// For a quit that was refused: the system has been told no.
    mutating func clear() {
        postedAt = nil
    }

    func isCurrent(at instant: ContinuousClock.Instant = .now) -> Bool {
        guard let postedAt else { return false }
        return postedAt.duration(to: instant) <= Self.lifetime
    }
}
