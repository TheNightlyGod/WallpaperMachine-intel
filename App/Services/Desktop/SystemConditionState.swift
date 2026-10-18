import Foundation

/// A condition of the whole Mac that a Playback & Power rule answers. Declared in the order the
/// panel names them when several hold: heat first, then Low Power Mode, then a low battery, as
/// `QualityReduction` does.
enum SystemCondition: String, CaseIterable, Comparable, Sendable {
    case heat
    case lowPowerMode
    case lowBattery

    /// The reduction this condition asks for when its rule chose Reduced quality.
    var qualityReduction: QualityReduction {
        switch self {
        case .heat: .heat
        case .lowPowerMode: .lowPowerMode
        case .lowBattery: .lowBattery
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (Self.allCases.firstIndex(of: lhs) ?? 0) < (Self.allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// One condition that holds now and what its rule does about it.
struct EngagedSystemCondition: Equatable, Sendable {
    /// What the rule does, weakest first: a stronger effect overrides a weaker one.
    enum Effect: String, CaseIterable, Comparable, Sendable {
        case reducedQuality
        case pause
        case stop

        static func < (lhs: Self, rhs: Self) -> Bool {
            (Self.allCases.firstIndex(of: lhs) ?? 0) < (Self.allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    let condition: SystemCondition
    /// The strongest thing it does. A hot Mac on Reduced quality pauses at critical, so it reads
    /// as a pause there.
    let effect: Effect
}

/// The conditions `SystemConditionMonitor` found engaged at its last evaluation, its low-battery
/// hysteresis included, in naming order. A condition whose rule keeps running, or that does not
/// hold, is not listed. Focus filters are not conditions: their own state reports them.
struct EngagedSystemConditions: Equatable, Sendable {
    private(set) var conditions: [EngagedSystemCondition] = []

    init(_ conditions: [EngagedSystemCondition] = []) {
        self.conditions = conditions.sorted { $0.condition < $1.condition }
    }

    var isEmpty: Bool { conditions.isEmpty }

    /// What `condition`'s rule does now; nil while it is not engaged.
    func effect(of condition: SystemCondition) -> EngagedSystemCondition.Effect? {
        conditions.first { $0.condition == condition }?.effect
    }

    /// The condition that pauses or stops wallpapers, the strongest effect first and, among equals,
    /// the one named first; nil while none does.
    var strongestRuleAction: EngagedSystemCondition? {
        conditions.filter { $0.effect > .reducedQuality }
            .min { $0.effect != $1.effect ? $0.effect > $1.effect : $0.condition < $1.condition }
    }
}

/// The engaged conditions the app's `SystemConditionMonitor` last published, for readers that do
/// not own the monitor: the control panel. Holds nothing of its own and is never persisted; it
/// posts `didChangeNotification` whenever the value changes.
@MainActor
final class SystemConditionState {
    static let shared = SystemConditionState()
    static let didChangeNotification = Notification.Name("WallpaperMachine.systemConditionsDidChange")

    private(set) var engaged = EngagedSystemConditions()

    func set(_ next: EngagedSystemConditions) {
        guard next != engaged else { return }
        engaged = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
