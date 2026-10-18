import SwiftUI

/// The wallpapers the target display showed recently, newest first, from the Now Playing card.
///
/// A row applies its wallpaper to the target display (the popover stays open, so a few can be tried
/// in a row); the one on show is marked Active. Clear history forgets this display's list and
/// leaves every other display and every file alone. Titles are the authors', so they are drawn as
/// text, never read as a localization key.
struct RecentlyUsedPopover: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  private static let rowHeight: CGFloat = 46
  private static let maxListHeight: CGFloat = 322

  var body: some View {
    let shell = controller.shell
    let rows = shell.recentlyUsed
    let target = controller.targetDisplay
    let isUsable = target?.isSelectable ?? false
    VStack(alignment: .leading, spacing: 0) {
      header(shell, displayTitle: target?.title ?? "")
      Divider()
      if rows.isEmpty {
        Text("No recent wallpapers for this display. Apply a wallpaper to start its history.")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(rows) { recent in
              RecentRow(recent: recent, isUsable: isUsable)
            }
          }
          .padding(6)
        }
        .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 12, Self.maxListHeight))
      }
      Divider()
      footer(shell, hasRows: !rows.isEmpty, isUsable: isUsable)
    }
    .frame(width: 330)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: L("Recently used")))
  }

  private func header(_ shell: ShellModel, displayTitle: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Recently used")
          .font(.system(size: 13, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: displayTitle)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      Button {
        shell.closePopover()
      } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.surface.muted.color)
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
      .help(L("Close history"))
      .accessibilityLabel(Text(verbatim: L("Close history")))
      .accessibilityIdentifier("history-close")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func footer(_ shell: ShellModel, hasRows: Bool, isUsable: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("Keeps the last 50 wallpapers used on this display.")
        .font(.system(size: 11))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
      if hasRows {
        Button("Clear history") { shell.clearHistory() }
          .buttonStyle(.link)
          .font(.system(size: 11.5))
          .disabled(
            !isUsable
              || controller.isBusy(
                PanelActionCoordinator.key("historyClear", displayID: controller.targetDisplayID))
          )
          .accessibilityIdentifier("history-clear")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

/// One wallpaper of the list: its cover, title and, for the one on show, an Active mark.
private struct RecentRow: View {
  let recent: RecentWallpaper
  let isUsable: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let key = PanelActionCoordinator.key("activate", id: recent.id)
    Button {
      controller.shell.apply(recent.id)
    } label: {
      HStack(spacing: 10) {
        PanelImage(source: recent.row.still, pointSize: 34, contentMode: .fill)
          .frame(width: 34, height: 34)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .accessibilityHidden(true)
        Text(verbatim: recent.row.title)
          .font(.system(size: 12.5))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if recent.isCurrent {
          CapsuleBadge(style: .accent) { Text("Active") }
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 40)
      .background(
        isHovering && isUsable ? theme.surface.hover.color : .clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!isUsable || controller.isBusy(key))
    .onHover { isHovering = $0 }
    .frame(height: 46)
    .accessibilityLabel(Text(verbatim: L("Apply \(recent.row.title)")))
    .accessibilityAddTraits(recent.isCurrent ? .isSelected : [])
    .accessibilityIdentifier("history-row-\(recent.id)")
  }
}
