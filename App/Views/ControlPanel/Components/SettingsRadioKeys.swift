import SwiftUI

/// Arrow keys in a group of choices, as a radio group has them: the arrow moves to the neighbour,
/// choosing it, and the keyboard focus goes with it. At either end the group wraps round.
///
/// Return and Space still press the choice that has the focus, being buttons. The group's own
/// `@FocusState` is passed in, so it lives in the view that owns the group.
struct SettingsRadioKeys<ID: Hashable>: ViewModifier {
  let id: ID
  /// Every choice of the group that can be moved to, in order.
  let ids: [ID]
  let focus: FocusState<ID?>.Binding
  let select: (ID) -> Void

  func body(content: Content) -> some View {
    content
      .focused(focus, equals: id)
      .onKeyPress(.leftArrow) { step(-1) }
      .onKeyPress(.upArrow) { step(-1) }
      .onKeyPress(.rightArrow) { step(1) }
      .onKeyPress(.downArrow) { step(1) }
  }

  private func step(_ delta: Int) -> KeyPress.Result {
    guard let index = ids.firstIndex(of: id), ids.count > 1 else { return .ignored }
    let neighbour = ids[(index + delta + ids.count) % ids.count]
    select(neighbour)
    focus.wrappedValue = neighbour
    return .handled
  }

  /// The choice the arrow lands on from `id`, for a test: the next in `delta`'s direction, wrapping.
  static func neighbour(of id: ID, in ids: [ID], delta: Int) -> ID? {
    guard let index = ids.firstIndex(of: id), ids.count > 1 else { return nil }
    return ids[(index + delta + ids.count) % ids.count]
  }
}

extension View {
  /// Makes a choice part of a radio-style group: see `SettingsRadioKeys`.
  func settingsRadioKeys<ID: Hashable>(
    _ id: ID, in ids: [ID], focus: FocusState<ID?>.Binding, select: @escaping (ID) -> Void
  ) -> some View {
    modifier(SettingsRadioKeys(id: id, ids: ids, focus: focus, select: select))
  }
}
