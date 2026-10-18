import SwiftUI

/// The row of views above the Library grid: All wallpapers and Favorites, each with its count, and
/// while a collection is on show, that collection too. One is lit: the view the grid shows.
///
/// Collections are chosen, made, renamed and deleted in the filters panel's Collections group; the
/// collection's chip here says which one is on show and puts it away. All wallpapers carries an
/// accent dot while Workshop wallpapers have an update, with how many as its tooltip and for
/// VoiceOver.
struct InstalledScopeBar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    // The counts say nothing while the library loads, when they would say there is nothing.
    let counts = controller.isLibraryLoading ? nil : controller.sidebarCounts
    let scope = model.scope
    HStack(spacing: 6) {
      ScopeChip(
        title: Text("All wallpapers"), systemImage: "square.grid.2x2", count: counts?.all,
        isOn: scope == .all, note: counts?.updateTooltip, identifier: "scope-all"
      ) { model.show(.all) }
      ScopeChip(
        title: Text("Favorites"), systemImage: "heart", count: counts?.favorites,
        isOn: scope == .favorites, identifier: "scope-favorites"
      ) { model.show(.favorites) }
      if let collection = model.shownCollection {
        let count = counts?.collections.first { $0.id == collection.id }?.count
        ScopeChip(
          title: Text(verbatim: collection.name), systemImage: "folder", count: count,
          isOn: true, closes: true, help: L("Show all wallpapers"), identifier: "scope-collection"
        ) { model.show(.all) }
        .frame(maxWidth: 260, alignment: .leading)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .frame(height: 34)
    .padding(.top, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Library"))
  }
}

/// One view of the library as a capsule: its symbol, its name and its count, tinted while it is the
/// one on show. A collection's chip ends in a cross, since pressing it puts the collection away.
private struct ScopeChip: View {
  let title: Text
  let systemImage: String
  let count: Int?
  let isOn: Bool
  var note: String?
  var closes = false
  /// The tooltip, when the note does not give one.
  var help: String?
  let identifier: String
  let action: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
        title.truncationMode(.tail)
        if let count {
          Text(count, format: .number)
            .monospacedDigit()
            .foregroundStyle(isOn ? theme.accent.accent.color : theme.surface.muted.color)
        }
        if note != nil {
          Circle().fill(.tint).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        if closes {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.panelCapsule(isActive: isOn))
    .help(note ?? help ?? "")
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

  /// The count first, then the update note.
  private var value: Text {
    let parts = [count.map { $0.formatted(.number.locale(PanelLocale.shared.locale)) }, note]
    return Text(verbatim: parts.compactMap { $0 }.joined(separator: ", "))
  }
}
