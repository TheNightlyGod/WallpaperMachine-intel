import Foundation
import Observation

/// The values of the Position on screen frame while they are being changed, and the queue that
/// sends them.
///
/// A drag or a slider changes the picture on every step, but the controller is asked once the change
/// settles. At most one request is in flight for each wallpaper and display; values that change
/// while it is on its way replace anything already waiting, and go out when it returns, so the end
/// of a drag is never lost behind an earlier send. The draft outlives every state the controller
/// publishes until the request that carried its final numbers has returned and no newer draft
/// exists. If the wallpaper or display changes under an unsent draft, the draft is sent for the one
/// it was made for and dropped. This is `placement.js`' draft queue, for a model that publishes
/// each saved placement as it is stored.
@MainActor
@Observable
final class PlacementDrafts {
  struct Target: Hashable, Sendable {
    let wallpaperID: String
    let displayID: String

    init(_ state: ImagePlacementState) {
      wallpaperID = state.wallpaperID
      displayID = state.displayID
    }
  }

  /// The values the user has moved; an axis they have not touched keeps the saved one.
  struct Draft: Equatable, Sendable {
    var x: Double?
    var y: Double?
    var zoom: Double?
  }

  struct Values: Equatable, Sendable {
    var x: Double
    var y: Double
    var zoom: Double
  }

  /// One send: the settled values, rounded, and the draft revision they came from.
  struct Request: Equatable, Sendable {
    let target: Target
    let x: Double
    let y: Double
    let zoom: Double
    let revision: Int
  }

  /// The values being changed and not yet saved.
  private(set) var draft: Draft?
  /// A Reset is on its way: the controls wait for it.
  private(set) var isResetting = false

  @ObservationIgnored private var draftRevision = 0
  @ObservationIgnored private var queuedDraftRevision = -1
  @ObservationIgnored private var waiting: [Target: Request] = [:]
  @ObservationIgnored private var order: [Target] = []
  @ObservationIgnored private var drainTask: Task<Void, Never>?
  @ObservationIgnored private var keyTask: Task<Void, Never>?
  @ObservationIgnored private var lastState: ImagePlacementState?

  @ObservationIgnored private let current: @MainActor () -> ImagePlacementState?
  @ObservationIgnored private let send: @MainActor (Request) async -> Bool
  @ObservationIgnored private let reset: @MainActor (Target) async -> Bool
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

  /// - Parameters:
  ///   - current: the controller's placement state now.
  ///   - send: asks the controller to place the picture; false when it was refused.
  ///   - reset: asks the controller to reset it; false when it was refused.
  init(
    current: @escaping @MainActor () -> ImagePlacementState?,
    send: @escaping @MainActor (Request) async -> Bool,
    reset: @escaping @MainActor (Target) async -> Bool,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.current = current
    self.send = send
    self.reset = reset
    self.sleep = sleep
  }

  // MARK: Reading

  /// What the frame and the sliders show: the saved placement, overridden by the draft.
  func values(for state: ImagePlacementState) -> Values {
    Values(
      x: PlacementGeometry.fraction(draft?.x ?? state.x, fallback: 0.5),
      y: PlacementGeometry.fraction(draft?.y ?? state.y, fallback: state.fit == .fillTop ? 0 : 0.5),
      zoom: PlacementGeometry.zoom(draft?.zoom ?? state.zoom))
  }

  /// Reset is offered once the picture has been moved, and not while one is on its way.
  func canReset(_ state: ImagePlacementState) -> Bool {
    !isResetting && (state.isCustomized || draft != nil)
  }

  // MARK: Changing

  /// Moves one or more axes of the draft; the frame follows at once.
  func update(x: Double? = nil, y: Double? = nil, zoom: Double? = nil) {
    var next = draft ?? Draft()
    if let x { next.x = PlacementGeometry.fraction(x, fallback: 0.5) }
    if let y { next.y = PlacementGeometry.fraction(y, fallback: 0.5) }
    if let zoom { next.zoom = PlacementGeometry.zoom(zoom) }
    draft = next
    draftRevision += 1
  }

  /// Puts back what a drag that did not move started from (a click on the frame).
  func restore(_ previous: Draft?) {
    draft = previous
    draftRevision += 1
  }

  /// Sends the settled values of `state`'s wallpaper and display. Returns the task that ends when
  /// every queued request has been answered; nil when there is nothing to send.
  @discardableResult
  func commit(from state: ImagePlacementState?) -> Task<Void, Never>? {
    guard let state, draft != nil else { return drainTask }
    let values = values(for: state)
    let target = Target(state)
    queuedDraftRevision = draftRevision
    if waiting[target] == nil { order.append(target) }
    waiting[target] = Request(
      target: target, x: PlacementGeometry.rounded(values.x), y: PlacementGeometry.rounded(values.y),
      zoom: PlacementGeometry.rounded(values.zoom), revision: draftRevision)
    return startDraining()
  }

  /// An arrow key on the frame: a step, Shift a bigger one, saved once the keys have paused.
  func nudge(dx: Int, dy: Int, large: Bool, state: ImagePlacementState) {
    let values = values(for: state)
    let moved = PlacementGeometry.nudged(x: values.x, y: values.y, dx: dx, dy: dy, large: large)
    update(x: moved.x, y: moved.y)
    keyTask?.cancel()
    let sleep = sleep
    keyTask = Task { @MainActor [weak self] in
      do { try await sleep(PlacementGeometry.keyDebounce) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.keyTask = nil
      await self.commit(from: self.current())?.value
    }
  }

  /// Puts the picture back where Image fit alone places it.
  @discardableResult
  func reset(_ state: ImagePlacementState) -> Task<Void, Never> {
    keyTask?.cancel()
    keyTask = nil
    isResetting = true
    let target = Target(state)
    return Task { @MainActor [weak self] in
      guard let self else { return }
      let succeeded = await self.reset(target)
      self.isResetting = false
      if succeeded {
        self.draft = nil
        self.draftRevision += 1
      }
    }
  }

  /// Follows the controller's state. When the wallpaper or display changes under a draft that was
  /// not yet sent, the draft goes out for the one it was made for; then it is dropped.
  func observe(_ state: ImagePlacementState?) {
    let before = lastState
    let beforeTarget = before.map(Target.init)
    let nextTarget = state.map(Target.init)
    if draft != nil, draftRevision != queuedDraftRevision, before != nil, beforeTarget != nextTarget {
      commit(from: before)
    }
    if beforeTarget != nextTarget {
      draft = nil
      draftRevision += 1
      keyTask?.cancel()
      keyTask = nil
    }
    lastState = state
  }

  /// Ends the key debounce and anything waiting, for a panel that is going away.
  func cancel() {
    keyTask?.cancel()
    keyTask = nil
  }

  // MARK: The queue

  private func startDraining() -> Task<Void, Never> {
    if let drainTask { return drainTask }
    let task = Task { @MainActor [weak self] in
      while let self, let target = self.order.first {
        self.order.removeFirst()
        guard let request = self.waiting.removeValue(forKey: target) else { continue }
        let succeeded = await self.send(request)
        if succeeded, let now = self.current(), Target(now) == request.target,
          self.draftRevision == request.revision
        {
          self.draft = nil
        }
      }
      self?.drainTask = nil
    }
    drainTask = task
    return task
  }
}
