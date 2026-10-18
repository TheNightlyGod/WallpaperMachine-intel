import SwiftUI

extension SteamGuardGuide {
  /// The SF Symbol on the card's tile: a phone for the Steam app, an envelope for the emailed code,
  /// a shield for a method this version does not know.
  var systemImage: String {
    switch self {
    case .mobileApproval, .authenticatorCode: "iphone"
    case .emailCode: "envelope"
    case .unknown: "shield"
    }
  }
}

/// A card that tells a person what to do next while Steam waits: a tinted tile with a symbol, a one
/// line title, numbered steps and a note, and whatever the caller adds below (a progress bar, a
/// status line).
///
/// The Steam Guard guides use it, and so do the dialog's connecting and signed-in cards and the
/// first-run guide's sign-in page. Its text is announced as a status, because it changes as Steam
/// answers. Titles and notes are already in the panel's language (they come from the model through
/// `L()`), so they are drawn as they are.
struct SteamGuideCard<Extra: View>: View {
  let systemImage: String
  let title: String
  var steps: [AttributedString] = []
  var note: String?
  @ViewBuilder var extra: Extra

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(theme.accent.accent.color)
        .frame(width: 36, height: 36)
        .background(
          theme.accent.accent.color.opacity(0.14),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: title)
          .font(.system(size: 13.5, weight: .semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .accessibilityAddTraits(.updatesFrequently)
        if !steps.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(index + 1)")
                  .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                  .foregroundStyle(theme.surface.muted.color)
                  .frame(width: 18, height: 18)
                  .background(theme.surface.badge.color, in: Circle())
                  .accessibilityHidden(true)
                Text(step)
                  .font(.system(size: 12.5))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              }
            }
          }
        }
        if let note {
          Text(verbatim: note)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        extra
      }
    }
    .padding(12)
    .foregroundStyle(theme.surface.text.color)
    .background(theme.surface.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: title))
  }
}

extension SteamGuideCard where Extra == EmptyView {
  init(systemImage: String, title: String, steps: [AttributedString] = [], note: String? = nil) {
    self.init(systemImage: systemImage, title: title, steps: steps, note: note) { EmptyView() }
  }
}

/// The steps for one Steam Guard method: which device to pick up, what to press and what to type.
/// Shared by the download dialog and the first-run guide, which both show it while a sign-in waits
/// for the person.
///
/// - Parameters:
///   - guide: what `SteamGuardGuide.guide(for:)` made of the job that is asking.
///   - account: the Steam account the request is for, shown in bold in the steps.
struct SteamSignInGuideView: View {
  let guide: SteamGuardGuide
  var account = ""

  var body: some View {
    SteamGuideCard(
      systemImage: guide.systemImage, title: guide.title, steps: guide.steps(account: account),
      note: guide.note)
  }
}

/// A notice inside a dialog: an error, a warning or a plain note, in the panel's own colours. An
/// error is announced, as an `alert` role was.
struct DownloadNotice: View {
  enum Kind { case error, warning, info }

  let kind: Kind
  let text: String
  /// A second line, such as the path of a retained copy.
  var detail: String?

  @Environment(\.panelTheme) private var theme

  private var color: Color {
    switch kind {
    case .error: theme.surface.danger.color
    case .warning: theme.surface.warning.color
    case .info: theme.accent.accent.color
    }
  }

  private var symbol: String {
    switch kind {
    case .error: "exclamationmark.triangle.fill"
    case .warning: "exclamationmark.circle.fill"
    case .info: "info.circle.fill"
    }
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: text)
        if let detail {
          Text(verbatim: detail).foregroundStyle(theme.surface.muted.color)
        }
      }
      .font(.system(size: 12))
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
    .onAppear { if kind == .error { AccessibilityNotification.Announcement(text).post() } }
  }
}
