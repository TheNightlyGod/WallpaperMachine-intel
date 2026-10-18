import SwiftUI

/// The strip above a page that reports what needs the person's attention: the error line, and the
/// wallpapers WallpaperMachine held back after crashing. Nothing is drawn, and no room is kept,
/// while there is nothing to report.
struct PanelBanners: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // The download failure shares the banner: the page showed one line, the first of the two.
    let message = controller.errors.message ?? controller.errors.downloadMessage
    let held = controller.heldWallpapers
    let hasContent = message != nil || !held.isEmpty
    VStack(spacing: 8) {
      if let message {
        ErrorBanner(message: message) { controller.dismissError() }
      }
      HeldWallpaperRows(rows: held)
    }
    .padding(.horizontal, hasContent ? 16 : 0)
    .padding(.vertical, hasContent ? 8 : 0)
    // Padding adds to a view's minimum width, and a minimum width in the detail column makes AppKit
    // throw "needing another Update Constraints in Window pass" when the window shrinks to its
    // floor in one step. The strip takes the width it is given.
    .frame(minWidth: 0)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasContent)
  }
}

/// The error line: the message, which wraps and can be selected and copied, and a Dismiss button.
private struct ErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    BannerRow(
      systemImage: "exclamationmark.triangle.fill", tint: theme.surface.danger.color,
      message: message
    ) {
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.surface.danger.color)
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
      .help(L("Dismiss error"))
      .accessibilityLabel(Text(verbatim: L("Dismiss error")))
      .accessibilityIdentifier("dismiss-error")
    }
    .accessibilityIdentifier("error-banner")
    .onAppear { announce() }
    .onChange(of: message) { announce() }
  }

  /// A failure that appears while VoiceOver is elsewhere is spoken, as an `alert` role was.
  private func announce() {
    AccessibilityNotification.Announcement(message).post()
  }
}

/// The rows for wallpapers the app held back after quitting unexpectedly while loading them, each
/// with a Try again button. A warning, not an error: it has no Dismiss, and it stays until the
/// wallpaper is released (a refused retry leaves it, and the error line says why). A row that
/// appears is spoken once, as the page's polite status line was.
struct HeldWallpaperRows: View {
  let rows: [HeldWallpaperRow]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    ForEach(rows) { row in
      BannerRow(
        systemImage: "exclamationmark.triangle", tint: theme.surface.warning.color,
        message: row.message
      ) {
        Button("Try again") { controller.shell.releaseHeld(row.id) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(controller.shell.isReleasingHeld(row.id))
          .accessibilityIdentifier("held-retry-\(row.id)")
      }
      .accessibilityIdentifier("held-banner-\(row.id)")
      .onAppear { controller.shell.announce(row.message) }
    }
  }
}

/// A tinted line with a leading symbol, wrapping text and a trailing control, used by both banners.
/// The text comes from services, bridges and wallpaper titles, so it is never read as a
/// localization key, and it can be selected to copy a path or a reason.
private struct BannerRow<Trailing: View>: View {
  let systemImage: String
  let tint: Color
  let message: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(verbatim: message)
        .font(.system(size: 12.5))
        .foregroundStyle(tint)
        .textSelection(.enabled)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(minWidth: 0)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }
}
