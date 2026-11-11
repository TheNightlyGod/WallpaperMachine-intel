import CoreAudio
import Foundation

struct ProcessAudioSample: Equatable, Sendable {
    var pid: pid_t
    var isRunningOutput: Bool
}

/// Sample of which processes are producing audio, plus a callback when that
/// sample may have changed. Core Audio work stays off the main thread.
protocol ProcessAudioSource: AnyObject {
    func sample() -> [ProcessAudioSample]
    /// Installed before each start. Asynchronous stop work must never clear a
    /// handler installed for a later start; the caller owns that lifecycle.
    var onChange: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

/// Private libSystem symbol. A WebContent or GPU process playing a web
/// wallpaper's audio has its own pid; counting it as another app would mute or
/// pause our own playback and never clear.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
func responsibilityGetPIDResponsibleForPID(_ pid: pid_t) -> pid_t

/// Reports whether any process other than this app (and the processes it is
/// responsible for) is producing audio output, leaving out the Mac's own
/// feedback sounds (`systemSoundServices`). Becoming active waits out a
/// short settle; becoming inactive waits longer so a gap between tracks does
/// not flap. Runs only while `otherAudioAction` is not `.keepRunning`.
@MainActor
final class OtherAudioMonitor {
    /// System programs whose output is the Mac's own feedback rather than another app
    /// playing: alerts and UI sounds, the login sound, the volume-change click and Siri
    /// listening, which keeps an output stream running while it waits. Matched by full
    /// path on the sealed system volume, so a program elsewhere with the same name still
    /// counts.
    nonisolated static let systemSoundServices: Set<String> = [
        "/usr/sbin/systemsoundserverd",
        "/usr/libexec/audiomxd",
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd",
        "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd_system",
    ]

    var onChange: (@MainActor () -> Void)?
    private(set) var isActive = false

    private let preferences: PlaybackPreferences?
    private let preferencesCenter: NotificationCenter
    private let source: ProcessAudioSource
    private let ownPID: pid_t
    private let responsiblePID: (pid_t) -> pid_t
    private let executablePath: (pid_t) -> String?
    private let activateDelay: Duration
    private let deactivateDelay: Duration

    private var preferencesObserver: NSObjectProtocol?
    private var settle: Task<Void, Never>?
    private var started = false
    private var sourceRunning = false

    init(
        preferences: PlaybackPreferences? = nil,
        preferencesCenter: NotificationCenter = .default,
        source: ProcessAudioSource? = nil,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        responsiblePID: ((pid_t) -> pid_t)? = nil,
        executablePath: ((pid_t) -> String?)? = nil,
        activateDelay: Duration = .milliseconds(500),
        deactivateDelay: Duration = .seconds(2)
    ) {
        self.preferences = preferences
        self.preferencesCenter = preferencesCenter
        self.source = source ?? CoreAudioProcessSource()
        self.ownPID = ownPID
        self.responsiblePID = responsiblePID ?? { responsibilityGetPIDResponsibleForPID($0) }
        self.executablePath = executablePath ?? { InstanceHandOff.executablePath(ofProcess: $0) }
        self.activateDelay = activateDelay
        self.deactivateDelay = deactivateDelay
    }

    func start() {
        guard !started else {
            refreshSource()
            return
        }
        started = true
        if let preferences {
            preferencesObserver = preferencesCenter.addObserver(
                forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSource() }
            }
        }
        refreshSource()
    }

    func stop() {
        started = false
        if let preferencesObserver {
            preferencesCenter.removeObserver(preferencesObserver)
            self.preferencesObserver = nil
        }
        settle?.cancel()
        settle = nil
        source.onChange = nil
        if sourceRunning {
            source.stop()
            sourceRunning = false
        }
        publish(false)
    }

    private var shouldListen: Bool {
        guard started else { return false }
        guard let preferences else { return true }
        return preferences.otherAudioAction != .keepRunning
    }

    private func refreshSource() {
        guard shouldListen else {
            settle?.cancel()
            settle = nil
            source.onChange = nil
            if sourceRunning {
                source.stop()
                sourceRunning = false
            }
            publish(false)
            return
        }
        if !sourceRunning {
            source.onChange = { [weak self] in self?.schedule() }
            sourceRunning = true
            source.start()
        }
        schedule()
    }

    private func othersProducing() -> Bool {
        source.sample().contains { sample in
            guard sample.isRunningOutput, sample.pid != ownPID else { return false }
            guard responsiblePID(sample.pid) != ownPID else { return false }
            guard let path = executablePath(sample.pid) else { return true }
            return !Self.systemSoundServices.contains(path)
        }
    }

    private func schedule() {
        guard shouldListen else { return }
        let active = othersProducing()
        settle?.cancel()
        settle = nil
        guard active != isActive else { return }
        let delay = active ? activateDelay : deactivateDelay
        guard delay > .zero else {
            publish(active)
            return
        }
        settle = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, self.shouldListen else { return }
            guard self.othersProducing() == active else { return }
            self.publish(active)
        }
    }

    private func publish(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onChange?()
    }
}

/// Core Audio HAL process list. Listeners run on a utility queue; `sample()` is
/// safe to call from the main actor.
private final class CoreAudioProcessSource: ProcessAudioSource, @unchecked Sendable {
    var onChange: (@MainActor () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return changeHandler
        }
        set {
            lock.lock()
            changeHandler = newValue
            lock.unlock()
        }
    }

    private let queue = DispatchQueue(label: "app.wallpapermachine.process-audio", qos: .utility)
    private let lock = NSLock()
    private var changeHandler: (@MainActor () -> Void)?
    private var cached: [ProcessAudioSample] = []
    private var running = false
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var refreshing = false
    private var refreshAgain = false

    func sample() -> [ProcessAudioSample] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func start() {
        queue.async { [weak self] in self?.install() }
    }

    func stop() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func install() {
        lock.lock()
        let already = running
        running = true
        lock.unlock()
        guard !already else {
            refresh()
            return
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr {
            listListener = block
        }
        refresh()
    }

    private func teardown() {
        lock.lock()
        running = false
        lock.unlock()
        if let listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listListener)
            self.listListener = nil
        }
        for (objectID, block) in processListeners {
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        }
        processListeners.removeAll()
        lock.lock()
        cached = []
        lock.unlock()
    }

    private func refresh() {
        lock.lock()
        let active = running
        lock.unlock()
        guard active else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }

        let ids = Self.processObjectIDs()
        let current = Set(ids)
        for objectID in processListeners.keys where !current.contains(objectID) {
            if let block = processListeners.removeValue(forKey: objectID) {
                var address = Self.address(kAudioProcessPropertyIsRunningOutput)
                AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
            }
        }
        for objectID in ids where processListeners[objectID] == nil {
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refresh()
            }
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
            if status == noErr {
                processListeners[objectID] = block
            }
        }

        let samples = ids.compactMap { objectID -> ProcessAudioSample? in
            guard let pid = Self.pid(of: objectID) else { return nil }
            return ProcessAudioSample(pid: pid, isRunningOutput: Self.isRunningOutput(objectID))
        }
        lock.lock()
        let changed = cached != samples
        cached = samples
        let handler = changeHandler
        lock.unlock()
        guard changed, let handler else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler() }
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let live = Int(size) / MemoryLayout<AudioObjectID>.stride
        return Array(ids.prefix(live))
    }

    private static func pid(of objectID: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0
        var address = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.stride)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
