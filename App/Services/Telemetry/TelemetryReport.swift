import Foundation

/// The performance report the app sends when the user has turned it on.
///
/// Every field is a number, a flag or one of a fixed set of words. There is no free
/// text anywhere in it: no title, path, display name, account or error message, so
/// nothing has to be redacted after the fact. The only identifier of a wallpaper is a
/// Steam Workshop id, which is public; every other wallpaper (an import, a pixiv save, a
/// picture) is sent as `nil`. `docs/features/telemetry.md` lists the fields, and the
/// website validates the same contract before it stores a row.
struct TelemetryReport: Codable, Equatable {
    static let schemaVersion = 1

    var schema = Self.schemaVersion
    var install: String
    var app: AppInfo
    var mac: MacInfo
    var sessions: [Session] = []
    var activations: [Activation] = []
    var frames: [Frame] = []
    var energy: [Energy] = []
    var loadStrikes: [LoadStrike] = []

    struct AppInfo: Codable, Equatable {
        var version: String
        var build: String
        /// Built from source rather than downloaded as the signed release.
        var source: Bool
    }

    struct MacInfo: Codable, Equatable {
        var model: String?
        var chip: String?
        var cores: Int
        var memoryGB: Int
        var os: String
        var gpu: String?
        var displays: [Display]
    }

    struct Display: Codable, Equatable {
        var width: Int
        var height: Int
        var scale: Double
        var hz: Int
        var main: Bool
    }

    /// One earlier run of the app.
    struct Session: Codable, Equatable {
        enum Ending: String, Codable {
            case clean, quitStalled, unexpected, systemRestart, exception
        }

        /// UTC day the run started.
        var day: String
        var app: String
        var ended: Ending
        /// Whether macOS left a crash report for it; nil when none was looked for.
        var crashReport: Bool?
        /// Nil when unknown. For a run that did not end cleanly it is the last checkpoint,
        /// so it is a lower bound.
        var minutes: Int?
        var pressureWarnings: Int
        var pressureCritical: Int
        var peakFootprintMB: Int?
    }

    struct Activation: Codable, Equatable {
        var day: String
        var type: String
        var wallpaper: String?
        var source: Source
        var kind: Kind
        var origin: String
        var outcome: String
        var ms: Int?
    }

    /// One rendered surface over one sampling window.
    struct Frame: Codable, Equatable {
        var day: String
        var wallpaper: String?
        var source: Source
        var kind: Kind
        var backend: String
        /// Always false since Native Metal became the only scene renderer. The key stays so a report keeps
        /// the shape the receiving end already reads.
        var fallback: Bool
        var mode: String
        var seconds: Double
        var tickHz: Double?
        var contentHz: Double?
        var draws: UInt64
        var dropped: UInt64
        var suppressed: UInt64
        var skippedUnchanged: UInt64
        var presents: UInt64
        var renderFailures: UInt64
        var displayWidth: Int?
        var displayHeight: Int?
        var displayHz: Int?
        var frameRateCap: Int?
        var renderScale: Double
        var reducedQuality: Bool
        var battery: Bool
        var lowPower: Bool
        var thermal: String
    }

    struct Energy: Codable, Equatable {
        var wallpaper: String?
        var source: Source
        var kind: Kind
        var milliwatts: Double
        var seconds: Double
        var displays: Int
        var frameRateCap: Int?
        var renderScale: Double
    }

    /// A Workshop wallpaper that was loading when the app stopped, and how often.
    struct LoadStrike: Codable, Equatable {
        var wallpaper: String
        var count: Int
    }

    enum Source: String, Codable {
        case workshop, local
    }

    enum Kind: String, Codable {
        case scene, video, web, unknown

        init(_ kind: BridgeWallpaperKind?) {
            switch kind {
            case .projectScene: self = .scene
            case .video: self = .video
            case .webpage: self = .web
            case .unknown, nil: self = .unknown
            }
        }
    }

    /// The most rows of each kind one report carries. When more pile up the oldest go.
    enum Limit {
        static let sessions = 30
        static let activations = 200
        static let frames = 50
        static let energy = 100
        static let loadStrikes = 50
    }
}

/// The one rule every wallpaper id in a report passes through.
enum TelemetryWallpaper {
    /// A Steam Workshop id is all digits. Anything else names a local wallpaper by its
    /// folder, which may be a person's own words, so it is never sent.
    static func workshopID(_ id: String) -> String? {
        guard (1...20).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return id
    }

    static func source(_ id: String) -> TelemetryReport.Source {
        workshopID(id) == nil ? .local : .workshop
    }
}

/// The fixed words a report may carry where the app's own value is a string.
enum TelemetryVocabulary {
    static let backends: Set<String> = ["native_metal"]
    static let modes: Set<String> = ["continuous", "waiting_for_event", "waiting_for_deadline"]

    static func backend(_ value: String) -> String { backends.contains(value) ? value : "unknown" }
    static func mode(_ value: String?) -> String { value.map { modes.contains($0) ? $0 : "unknown" } ?? "unknown" }

    static func outcome(_ outcome: ActivationLog.Outcome) -> String {
        switch outcome {
        case .applied: "applied"
        case .noOp: "noOp"
        case .skipped: "skipped"
        case let .failed(failure): failure.rawValue
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    static func ending(_ outcome: SessionLedger.Outcome) -> TelemetryReport.Session.Ending? {
        switch outcome {
        case .firstRun: nil
        case .cleanQuit: .clean
        case .quitStalled: .quitStalled
        case .endedUnexpectedly: .unexpected
        case .systemRestart: .systemRestart
        case .exception: .exception
        }
    }
}

/// UTC calendar days, the only time a report states.
enum TelemetryDay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
