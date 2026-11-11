import SwiftUI

/// Where the download dialog is presented, as a sheet. The root mounts it in the window's
/// background, so the dialog can open from any page: a ring on a tile, Settings, a password prompt
/// arriving while another page is on show.
///
/// It also keeps the dialog following the requests and the jobs while the window is up
/// (`DownloadsModel.start()`): the dialog closes when it has nothing left to say, and opens by itself
/// for a password or a Steam Guard answer that Steam waits on and the person has not dismissed.
struct DownloadDialogHost: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.downloads
    Color.clear
      .frame(width: 0, height: 0)
      // Escape, the close button and a click outside all arrive as `false`: each is **Not now**,
      // which also silences the request that is asking.
      .sheet(
        isPresented: Binding(
          get: { model.isDialogOpen }, set: { if !$0 { model.closeDialog() } })
      ) {
        DownloadDialogView().panelPresentationLocale()
      }
      .onAppear { model.start() }
      .onDisappear { model.stop() }
  }
}
