import Foundation
import IOKit.ps

/// Tells the app when the Mac moves between mains and battery power.
///
/// The renderer watches the same source and applies the battery policy (Pause,
/// Reduced quality) inside the bridge, but it reports nothing back, and the hosts
/// that live in this process read their pause, frame-rate limit and render scale
/// from the bridge only when a snapshot is applied. Without a trigger, plugging in
/// would leave a web page detached behind the battery Pause until some unrelated
/// snapshot arrived. Only the system notification is observed; nothing is polled.
@MainActor
final class PowerSourceMonitor {
    /// The renderer's own reading of the same system value: mains power, a battery
    /// (a UPS counts as one) or neither.
    enum Source: Equatable {
        case mains, battery, unknown
    }

    var onChange: (@MainActor (Source) -> Void)?
    private(set) var source: Source

    private let read: @MainActor () -> Source
    private var runLoopSource: CFRunLoopSource?

    init(read: @escaping @MainActor () -> Source = PowerSourceMonitor.systemSource) {
        self.read = read
        source = read()
    }

    deinit {
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
    }

    /// The system's current providing power source.
    static func systemSource() -> Source {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch providing {
        case kIOPMACPowerKey: return .mains
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    func start() {
        guard runLoopSource == nil else { return }
        // The context is not retained: `stop()` takes the source off the run loop
        // before this object can go, and the callback only ever runs on the main
        // thread, where this object lives.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleChange() }
        }, context)?.takeRetainedValue() else {
            AppLog.warn("power source changes cannot be observed; hosts follow the next snapshot")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        runLoopSource = created
        // A change between construction and now.
        handleChange()
    }

    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CFRunLoopSourceInvalidate(runLoopSource)
        self.runLoopSource = nil
    }

    /// What the system notification does. The notification also fires for the
    /// battery's charge level, so only a different source is reported.
    func handleChange() {
        let next = read()
        guard next != source else { return }
        AppLog.info("power source changed to \(next)")
        source = next
        onChange?(next)
    }
}

/// Brings the app's snapshot level with a power change.
///
/// The renderer and this process hear about a plug or unplug independently, so a
/// snapshot taken right after the notification may still be the one from before
/// it. The renderer's answer is in the snapshot (`onBatteryPower`), so the refresh
/// repeats, a little later each time, until the snapshot agrees with what the
/// system said. Every refresh applies a snapshot, which is what the hosts here
/// reconcile on; a renderer that never agrees ends the loop after the last delay.
enum PowerSourceRefresh {
    static let retryDelays: [Duration] = [.milliseconds(150), .milliseconds(400), .seconds(1), .seconds(2)]

    /// Whether a refresh showed the renderer on the expected source. A refresh
    /// that fails is retried like one that disagrees; cancellation ends the loop.
    @MainActor
    @discardableResult
    static func run(
        expectedOnBattery: Bool,
        refresh: () async throws -> Void,
        bridgeOnBattery: () -> Bool,
        delays: [Duration] = retryDelays,
        wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        var pending: [Duration?] = [nil]
        pending.append(contentsOf: delays.map { Optional($0) })
        for delay in pending {
            if let delay {
                do { try await wait(delay) } catch { return false }
            }
            guard !Task.isCancelled else { return false }
            do {
                try await refresh()
                if bridgeOnBattery() == expectedOnBattery { return true }
            } catch {
                AppLog.warn("snapshot refresh after a power source change failed: \(error.localizedDescription)")
            }
        }
        return false
    }
}
