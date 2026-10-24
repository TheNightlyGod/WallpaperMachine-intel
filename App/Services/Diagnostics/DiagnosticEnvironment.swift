import AppKit
import Metal

/// What a bug report needs to know about the machine before anything about a
/// wallpaper: app build, macOS, hardware, GPU, language and displays.
///
/// One fact per line. Written at the top of every log session and into
/// `environment.txt` of an exported diagnostics bundle, where the displays are
/// read again because they may have changed since launch.
enum DiagnosticEnvironment {
    @MainActor
    static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> [String] {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let memory = Double(processInfo.physicalMemory) / 1_073_741_824
        var lines = [
            "app \(bundle.bundleIdentifier ?? "unknown") \(version) (\(build)) at \(bundle.bundlePath)",
            "macOS \(processInfo.operatingSystemVersionString)",
            "hardware \(sysctl("hw.model") ?? "unknown"), \(sysctl("machdep.cpu.brand_string") ?? "unknown cpu"), "
                + "\(processInfo.activeProcessorCount) cores, \(String(format: "%.0f", memory)) GB memory",
            "gpu \(MTLCreateSystemDefaultDevice()?.name ?? "none")",
            "power low-power mode \(processInfo.isLowPowerModeEnabled ? "on" : "off"), "
                + "thermal state \(thermalState(processInfo.thermalState))",
            "language \(Locale.preferredLanguages.joined(separator: ",")), locale \(Locale.current.identifier), "
                + "time zone \(TimeZone.current.identifier)",
        ]
        let main = NSScreen.main
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let scale = screen.backingScaleFactor
            let width = Int((screen.frame.width * scale).rounded())
            let height = Int((screen.frame.height * scale).rounded())
            lines.append("""
                display \(id) "\(screen.localizedName)": \(width)x\(height) px @\(scale.formatted())x, \
                \(screen.maximumFramesPerSecond) Hz\(screen == main ? ", main" : "")
                """)
        }
        return lines
    }

    /// One running scene as the report states it: where it plays, which renderer
    /// drew it and, when the renderer's live read-back has a row for the same
    /// display, what it is doing right now.
    ///
    /// `mode` is the bridge's own name for the live state. A scene that stopped
    /// drawing after a failure reads `stopped_after_failure` here, which is the
    /// line a bug report needs to tell it from one the user paused. No row means
    /// no reading, and the line then says nothing about the mode rather than
    /// guessing one.
    static func runningSceneLine(_ scene: BridgeSceneBackendReport, mode: String?) -> String {
        var line =
            "running scene: display \(scene.displayId) \"\(scene.displayName)\", wallpaper "
            + "\(scene.wallpaperId) \"\(scene.wallpaperTitle)\", backend \(scene.backend)"
        if let stage = scene.failureStage {
            line += " (not drawn, \(stage)\(scene.failureReason.map { ": \($0)" } ?? ""); holding the last picture)"
        }
        line += ", video path \(scene.videoPath)"
        if let mode { line += ", mode \(mode)" }
        return line
    }

    /// One display's size and rate as a load header names them.
    @MainActor
    static func display(_ displayID: UInt32) -> String {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else {
            return "display \(displayID) (not connected)"
        }
        let scale = screen.backingScaleFactor
        return "display \(displayID) \(Int((screen.frame.width * scale).rounded()))x"
            + "\(Int((screen.frame.height * scale).rounded())) @\(scale.formatted())x "
            + "\(screen.maximumFramesPerSecond)Hz"
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
