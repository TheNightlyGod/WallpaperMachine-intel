import SwiftUI

/// The toolbar button that opens the Downloads list: a download arrow that rings itself with the
/// batch's progress while anything transfers, and the number of downloads beside it.
///
/// It is in the toolbar only once there is something to list, so a window with no downloads has no
/// button. The tiles and the inspector carry each download's own state; this carries the batch's.
struct DownloadsToolbarButton: View {
  /// Whether the toolbar shows the button: a download, a request waiting for a prerequisite, or a
  /// pixiv save. A finished sign-in is not a download and does not count while it is over.
  ///
  /// The toolbar asks on every change of the window's content, so this reads only what changes when
  /// a download starts or ends (the lists and the sign-in's state), never a job's progress.
  static func isActive(in controller: PanelController) -> Bool {
    let workshop = controller.workshop
    if !workshop.downloadRequests.isEmpty { return true }
    if workshop.downloader.downloads.contains(where: { !$0.isSignIn || $0.isPending }) {
      return true
    }
    return !controller.pixiv.downloads.downloads.isEmpty
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    @Bindable var model = controller.downloads
    let queue = controller.downloadQueue
    Button {
      model.isQueuePopoverOpen.toggle()
    } label: {
      HStack(spacing: 5) {
        ZStack {
          if queue.showsRing {
            // A ring with a figure, or a sweeping arc while no job has one yet; the arc moves only
            // while the window is on screen.
            ProgressRing(value: queue.progress, lineWidth: 2)
              .frame(width: 22, height: 22)
          }
          Image(systemName: "arrow.down")
            .font(.system(size: 11, weight: .bold))
        }
        .frame(width: 22, height: 22)
        if queue.count > 0 {
          CountBadge(count: queue.count, style: queue.needsAttention ? .attention : .neutral)
        }
      }
    }
    .help(queue.buttonLabel)
    .accessibilityLabel(Text(verbatim: queue.buttonLabel))
    .accessibilityIdentifier("downloads-button")
    .popover(isPresented: $model.isQueuePopoverOpen, arrowEdge: .bottom) {
      DownloadsPopover().panelPresentationLocale()
    }
  }
}
