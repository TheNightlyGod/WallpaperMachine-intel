import Foundation

/// Connects one slider or colour to the controller's drag pump, and tells a drag from a key press.
///
/// This is the wiring the controller leaves to the view (`CONTRACTS` section 3). A pointer drag
/// creates a pump on its first value (`update`), which shows the wallpaper at the thumb without
/// saving anything; the release (`release`) saves the value the drag settled on through the pump, so
/// the step already on its way lands first and the commit always happens. A key press or a
/// VoiceOver change (`step`) skips the pump and commits at once. Both start their commit with
/// `launch` under `key` with `.latestWins`, so the newest value lands last and a refusal reaches
/// the error banner.
@MainActor
final class PumpedDrag<Value: Equatable & Sendable> {
  private unowned let controller: PanelController
  private let key: String
  private let makePump: @MainActor () -> DragStepPump<Value>
  private let commit: @MainActor (Value) async throws -> Void
  private var pump: DragStepPump<Value>?

  init(
    controller: PanelController, key: String,
    makePump: @escaping @MainActor () -> DragStepPump<Value>,
    commit: @escaping @MainActor (Value) async throws -> Void
  ) {
    self.controller = controller
    self.key = key
    self.makePump = makePump
    self.commit = commit
  }

  /// A drag has reported a value and has not been released.
  var isDragging: Bool { pump?.isDragging == true }
  /// What a release on blur or cancel settles with.
  var newestValue: Value? { pump?.newestValue }

  /// The pointer moved the control. `deferFirstStep` is for a colour picker, whose drag happens in
  /// a panel of its own: a single pick, whose commit follows at once, shows no step first.
  func update(_ value: Value, deferFirstStep: Bool = false) {
    let pump = pump ?? makePump()
    self.pump = pump
    pump.update(value, deferFirstStep: deferFirstStep)
  }

  /// The pointer came up (or the control lost the drag): saves `value` after the step in flight.
  @discardableResult
  func release(_ value: Value) -> Task<Void, Never> {
    let active = pump ?? makePump()
    pump = nil
    let commit = commit
    return controller.launch(key, policy: .latestWins) {
      try await active.release(value, commit: commit)
    }
  }

  /// A key press or an accessibility action: saved at once, never previewed.
  @discardableResult
  func step(_ value: Value) -> Task<Void, Never> {
    let commit = commit
    return controller.launch(key, policy: .latestWins) { try await commit(value) }
  }

  /// A drag that was cut off (the view went away, the window lost focus): settles with the newest
  /// value, so the wallpaper is put back at a saved value.
  @discardableResult
  func settle() -> Task<Void, Never>? {
    guard let value = newestValue else { return nil }
    return release(value)
  }
}

extension PumpedDrag where Value == PropertyDragValue {
  /// The driver of one property's slider or colour: the controller's property pump for each drag, and
  /// `commitProperty` for what is saved, under the property's key with `.latestWins`.
  static func property(
    controller: PanelController, wallpaperID: String, property propertyID: String,
    sleep: @escaping DragStepPump<PropertyDragValue>.Sleep = { try await Task.sleep(for: $0) }
  ) -> PumpedDrag<PropertyDragValue> {
    PumpedDrag(
      controller: controller, key: InspectorAction.property(wallpaperID, propertyID),
      makePump: {
        controller.propertyDragPump(wallpaperID, property: propertyID, sleep: sleep)
      },
      commit: { value in
        try await controller.commitProperty(
          wallpaperID, property: propertyID, value: value.bridgeValue)
      })
  }
}

extension PumpedDrag where Value == PropertyDragValue {
  /// The driver of one Wallpaper Engine option's slider: the option's pump for each drag and
  /// `commitEngineOption` for what is saved, under the option's key with `.latestWins`.
  static func engineOption(
    controller: PanelController, wallpaperID: String, option: BridgeEngineOptionId,
    sleep: @escaping DragStepPump<PropertyDragValue>.Sleep = { try await Task.sleep(for: $0) }
  ) -> PumpedDrag<PropertyDragValue> {
    PumpedDrag(
      controller: controller, key: InspectorAction.engineOption(wallpaperID, option),
      makePump: {
        controller.engineOptionDragPump(wallpaperID, option: option, sleep: sleep)
      },
      commit: { value in
        try await controller.commitEngineOption(wallpaperID, option: option, value: value.bridgeValue)
      })
  }
}

extension PumpedDrag where Value == Double {
  /// The driver of one axis of a display's position sliders: the position pump for each drag and
  /// `setDisplayPosition` with only that axis for what is saved. Both axes of a display share the
  /// key, so their saves go out one after the other.
  static func position(
    controller: PanelController, wallpaperID: String, display displayID: String,
    axis: PanelController.PositionAxis,
    sleep: @escaping DragStepPump<Double>.Sleep = { try await Task.sleep(for: $0) }
  ) -> PumpedDrag<Double> {
    PumpedDrag(
      controller: controller, key: InspectorAction.displayPosition(wallpaperID, display: displayID),
      makePump: {
        controller.displayPositionDragPump(wallpaperID, display: displayID, axis: axis, sleep: sleep)
      },
      commit: { value in
        try await controller.setDisplayPosition(
          wallpaperID, display: displayID, x: axis == .horizontal ? value : nil,
          y: axis == .vertical ? value : nil)
      })
  }
}

/// A colour well's drag, which the view cannot see: the picker is a panel of its own and reports
/// each change, never the end. A burst of changes is a drag (steps at most every 100 ms); the colour
/// is saved once changes have paused for the quiet period, or when the colour panel closes.
@MainActor
final class ColorPickDriver {
  /// How long the colour must stay put to count as chosen.
  nonisolated static let quietPeriod: Duration = .milliseconds(350)

  private let drag: PumpedDrag<PropertyDragValue>
  private let quietPeriod: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var quiet: Task<Void, Never>?

  init(
    drag: PumpedDrag<PropertyDragValue>, quietPeriod: Duration = ColorPickDriver.quietPeriod,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.drag = drag
    self.quietPeriod = quietPeriod
    self.sleep = sleep
  }

  var isPicking: Bool { drag.isDragging }

  /// The picker reported a colour (components from 0 to 1).
  func pick(red: Double, green: Double, blue: Double) {
    drag.update(.color(red: red, green: green, blue: blue), deferFirstStep: true)
    quiet?.cancel()
    let period = quietPeriod
    let sleep = sleep
    quiet = Task { @MainActor [weak self] in
      do { try await sleep(period) } catch { return }
      guard !Task.isCancelled else { return }
      self?.finish()
    }
  }

  /// The colour panel closed (or the view went away): whatever was picked is chosen.
  func finish() {
    quiet?.cancel()
    quiet = nil
    drag.settle()
  }
}
