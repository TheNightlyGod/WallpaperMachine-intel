import SwiftUI

extension TargetDisplayOption {
  /// The display as the menu lists it. A mirror or a disabled display says so, and a mirror's word
  /// wins when it is both; they are whole phrases so a language can place the word where it
  /// belongs.
  @MainActor
  var menuLabel: String { label(naming: title) }

  /// The display as the toolbar button names it, which has room for little more than a name: the
  /// screen's name without the renderer's `(id - Role)` group, unless another display has the
  /// same name, when only the full title tells them apart. The menu, the help and VoiceOver keep
  /// the full title.
  @MainActor
  func shortLabel(among displays: [TargetDisplayOption]) -> String {
    let name = Self.name(of: title)
    let isShared = displays.contains { $0.id != id && Self.name(of: $0.title) == name }
    return label(naming: isShared ? title : name)
  }

  /// A display title without the renderer's trailing `(id - Role)` group (`Studio Display
  /// (2 - Primary)` is `Studio Display`). A title without one, or with nothing in front of it, is
  /// returned as it is.
  static func name(of title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("),
      trimmed[open...].contains(" - ")
    else { return title }
    let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? title : name
  }

  @MainActor
  private func label(naming name: String) -> String {
    if isMirror { return L("\(name) (mirrored)") }
    return isEnabled ? name : L("\(name) (disabled)")
  }
}

/// The display that wallpapers are applied to, chosen from a menu in the toolbar.
///
/// Every display is listed, but only an enabled one that plays its own wallpaper can be chosen; a
/// mirrored or disabled one says so and is greyed out. A wide window names the chosen display next
/// to the icon; a narrow one (`ShellModel.isCompact`) shows the icon alone. The menu is unavailable while a command is
/// running, and the toolbar does not show it on Settings. A display that has left the list or can no
/// longer be chosen leaves the menu reading "Target display": the choice is kept, and the person
/// picks another.
struct TargetDisplayPicker: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let shell = controller.shell
    let displays = controller.targetDisplays
    let target = controller.targetDisplayID
    let current = displays.first { $0.id == target }
    let selection = Binding(
      get: { target },
      set: { shell.setTarget($0) })
    Menu {
      Picker(selection: selection) {
        ForEach(displays) { display in
          Text(verbatim: display.menuLabel).tag(display.id).disabled(!display.isSelectable)
        }
      } label: {
        Text("Target display")
      }
      .pickerStyle(.inline)
    } label: {
      // The toolbar draws a `Label` as its icon alone, so a wide window spells the icon and the
      // name out side by side; a narrow one keeps the icon, and the help names the display.
      if shell.isCompact {
        Label(L("Target display"), systemImage: "display")
      } else {
        HStack(spacing: 6) {
          Image(systemName: "display")
          Text(verbatim: current?.shortLabel(among: displays) ?? L("Target display"))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: 180)
      }
    }
    .disabled(controller.isStoreBusy)
    .help(helpText(current))
    .accessibilityLabel(Text(verbatim: L("Target display")))
    .accessibilityValue(Text(verbatim: current?.menuLabel ?? ""))
    .accessibilityIdentifier("target-display")
  }

  /// What the button is for, and the display's full title, which the button may shorten.
  private func helpText(_ current: TargetDisplayOption?) -> String {
    let purpose = L("Wallpapers you apply go to this display")
    guard let current else { return purpose }
    return "\(current.menuLabel)\n\(purpose)"
  }
}
