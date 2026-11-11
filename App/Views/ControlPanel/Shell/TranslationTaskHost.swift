import SwiftUI
import Translation

/// Where the panel lends the Translation framework's sessions to `TranslationSessionHost`: SwiftUI's
/// `.translationTask` on a clear layer behind the window's content. Before macOS 26 a session exists
/// nowhere else, and a language download always needs one, whose prompt the framework shows in this
/// window. The view hands each session over and does nothing itself; while nothing asks for one the
/// configuration is nil and no task runs.
struct TranslationTaskHost: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let host = controller.searchTranslation.sessionHost
    Color.clear
      .translationTask(host.configuration) { session in await host.serve(session) }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
