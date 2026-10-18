import SwiftUI

/// The toolbar pill that reports pixiv saves in progress, on every page, and leads back to the
/// pixiv page: "pixiv: Title · 42%" for one save, "3 pixiv downloads" for several.
///
/// In a compact window (`ShellModel.isCompact`) the pill keeps only its ring and a figure ("42%",
/// "3"), with the whole label in its tooltip and for VoiceOver. It only navigates, so it gives way
/// before the controls that act: at the smallest window the full label pushed the Downloads button
/// and the inspector toggle into the toolbar's overflow menu.
struct PixivActivityPill: View {
  /// Whether the toolbar shows the pill, while a pixiv save is pending. The toolbar asks before it
  /// adds the item, so an idle pill leaves no gap. Only each job's status is read, so the toolbar
  /// is evaluated again when a save starts or ends, never on its progress ticks; the pill's own
  /// body reads the progress it shows.
  static func isActive(in controller: PanelController) -> Bool {
    controller.pixiv.downloads.downloads.contains(where: \.isPending)
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    if let activity = controller.pixivActivity {
      let label = activity.label
      let isCompact = controller.shell.isCompact
      Button {
        // The shell's navigation: one latest-wins chain with the tabs, so the newest page wins.
        controller.shell.open(.pixiv)
      } label: {
        HStack(spacing: 6) {
          ProgressRing(value: activity.percent.map { Double($0) / 100 }, lineWidth: 2)
            .frame(width: 14, height: 14)
          if isCompact {
            if let figure = activity.figure {
              Text(verbatim: figure)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .lineLimit(1)
            }
          } else {
            Text(verbatim: label)
              .font(.system(size: 12, weight: .medium))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: 200)
          }
        }
      }
      .help(label)
      .accessibilityLabel(label)
      .accessibilityIdentifier("pixiv-activity-pill")
    }
  }
}

extension PixivActivity {
  /// What the compact pill says beside its ring: the share of a single save ("42%"), or how many
  /// saves there are ("3"); nil for a single save whose size is not known yet, where the moving
  /// ring says it alone.
  var figure: String? {
    guard jobCount == 1 else { return "\(jobCount)" }
    return percent.map { "\($0)%" }
  }
}
