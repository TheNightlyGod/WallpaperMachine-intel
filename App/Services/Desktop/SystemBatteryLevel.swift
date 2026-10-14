import Foundation
import IOKit.ps

/// One reading of the Mac's internal battery: how full it is and whether the Mac is running on
/// it right now.
struct BatteryReading: Equatable, Sendable {
    var percent: Int
    var isDischarging: Bool

    init(percent: Int, isDischarging: Bool) {
        self.percent = percent
        self.isDischarging = isDischarging
    }

    /// Reads one power-source description from IOKit. Only the internal battery counts: a UPS or
    /// any other source gives nil, and so does a description whose capacity cannot be turned
    /// into a percentage.
    init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              maximum > 0, current.isFinite, maximum.isFinite else { return nil }
        percent = Int(min(100, max(0, (current * 100 / maximum).rounded(.down))))
        isDischarging = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
    }

    /// The internal battery as it is now, or nil on a Mac without one or when IOKit cannot say.
    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let reading = BatteryReading(description: description) else { continue }
            return reading
        }
        return nil
    }
}

/// Decides when the charge counts as low. It engages once the Mac runs on its battery at or
/// below the threshold and releases only `releaseMargin` points above it, so a charge that
/// hovers around the level does not pause and resume the wallpapers over and over. Plugging in,
/// or having no battery to read, releases at any charge.
struct LowBatteryGate: Equatable, Sendable {
    static let releaseMargin = 5

    private(set) var isEngaged = false

    @discardableResult
    mutating func update(_ reading: BatteryReading?, threshold: Int) -> Bool {
        guard let reading, reading.isDischarging else {
            isEngaged = false
            return false
        }
        if isEngaged {
            if reading.percent >= threshold + Self.releaseMargin { isEngaged = false }
        } else if reading.percent <= threshold {
            isEngaged = true
        }
        return isEngaged
    }

    mutating func reset() { isEngaged = false }
}

/// Where `SystemConditionMonitor` learns about the battery, so a test can drive it.
@MainActor
protocol BatteryLevelSource: AnyObject {
    /// The battery as it is now, read fresh.
    var reading: BatteryReading? { get }
    /// Calls `onChange` on the main actor whenever the reading differs from the one before.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// The battery source of the real Mac. IOKit posts a power-source notification when the charge
/// or the power source changes; nothing is polled, and nothing is registered between `start()`
/// and `stop()`. While started it keeps itself alive, because the run-loop source hands IOKit a
/// bare pointer, and releases itself in `stop()`.
@MainActor
final class SystemBatteryLevel: BatteryLevelSource {
    private var source: CFRunLoopSource?
    private var retainedSelf: Unmanaged<SystemBatteryLevel>?
    private var onChange: (@MainActor () -> Void)?
    private var last: BatteryReading?

    var reading: BatteryReading? { BatteryReading.read() }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard source == nil else { return }
        last = BatteryReading.read()
        let retained = Unmanaged.passRetained(self)
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let level = Unmanaged<SystemBatteryLevel>.fromOpaque(context).takeUnretainedValue()
            // The source is added to the main run loop, so this already runs on the main thread.
            MainActor.assumeIsolated { level.sourceFired() }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, retained.toOpaque())?.takeRetainedValue() else {
            retained.release()
            AppLog.error("battery level: could not observe power-source changes")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
        retainedSelf = retained
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        onChange = nil
        last = nil
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func sourceFired() {
        let current = BatteryReading.read()
        guard current != last else { return }
        last = current
        onChange?()
    }
}
