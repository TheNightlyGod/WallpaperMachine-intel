import SwiftUI

/// The download dialog: one sheet that walks a download through what it still needs (SteamCMD, the
/// Steam account, the consent to download the shared resources, Steam's password and Steam Guard)
/// and says so once the sign-in is done.
///
/// What it shows is `DownloadsModel.resolution`; the dialog only draws it. A stage changes under the
/// person's hands while they read it, so focus moves only when the dialog opens or what it is about
/// changes (`focusKey`), never on a progress update: typing is not interrupted.
struct DownloadDialogView: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// The last session and resolution that were live, which the sheet keeps drawing while it fades
  /// out, after the model has already let go of them.
  @State private var heldSession: DownloadsModel.Session?
  @State private var heldResolution: DownloadDialogResolution?
  @State private var bodyHeight: CGFloat = 160
  /// What the person typed in the password or code field. It lives only here, is cleared the moment
  /// it is submitted and never reaches an observable model.
  @State private var response = ""
  @FocusState private var focus: Field?

  enum Field: Hashable { case account, response }

  /// A session and resolution to draw instead of the model's, for a test that renders a stage the
  /// stores would need a live Steam sign-in to reach.
  private let fixedSession: DownloadsModel.Session?
  private let fixedResolution: DownloadDialogResolution?

  init(session: DownloadsModel.Session? = nil, resolution: DownloadDialogResolution? = nil) {
    fixedSession = session
    fixedResolution = resolution
  }

  /// The tallest the scrolling body grows before it scrolls instead.
  private static let maxBodyHeight: CGFloat = 480

  var body: some View {
    let model = controller.downloads
    let session = fixedSession ?? model.session ?? heldSession
    let resolution = fixedResolution ?? model.resolution ?? heldResolution
    VStack(spacing: 0) {
      if let session, let resolution {
        header(resolution)
        Divider()
        ScrollView {
          stageBody(session: session, resolution: resolution)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
        }
        .frame(height: min(max(bodyHeight, 80), Self.maxBodyHeight))
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .frame(width: 460)
    .foregroundStyle(theme.surface.text.color)
    .background(theme.surface.background.color)
    .onChange(of: model.resolution, initial: true) {
      if let resolution = model.resolution {
        heldResolution = resolution
        heldSession = model.session
      }
    }
    // Focus moves when the dialog is about something new, and the typed secret never carries over
    // to another prompt.
    .onChange(of: model.focusKey, initial: true) {
      response = ""
      moveFocus(model.resolution)
    }
  }

  private func moveFocus(_ resolution: DownloadDialogResolution?) {
    let target: Field?
    switch resolution?.stage {
    case .account: target = .account
    case .auth: target = resolution?.job?.prompt != nil ? .response : nil
    default: target = nil
    }
    // The sheet is not key yet on its first pass; the next turn is.
    Task { @MainActor in focus = target }
  }

  // MARK: Header

  /// The symbol the header shows where the subject has no picture of its own, which the shared
  /// scene resources and the Steam sign-in never have (and an item may lack): a symbol of what the
  /// dialog is about, never an empty frame. Nil when there is a picture to show.
  static func placeholderSymbol(for resolution: DownloadDialogResolution) -> String? {
    guard resolution.image == nil else { return nil }
    switch resolution.subjectID {
    case WorkshopStore.sceneAssetsRequestID: return "shippingbox"
    case WorkshopStore.signInRequestID: return "person.badge.key"
    default: return "photo"
    }
  }

  private func header(_ resolution: DownloadDialogResolution) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Group {
        if let symbol = Self.placeholderSymbol(for: resolution) {
          // Drawn as the stage cards draw their symbols: the accent on a tint of it.
          Image(systemName: symbol)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(theme.accent.accent.color)
            .frame(width: 52, height: 52)
            .background(
              theme.accent.accent.color.opacity(0.14),
              in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
          PanelImage(source: resolution.image, pointSize: 56)
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
            }
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: resolution.title)
          .font(.system(size: 16, weight: .semibold))
          .lineLimit(2)
          .textSelection(.enabled)
          .accessibilityAddTraits(.isHeader)
        // The item's title comes from the Workshop, so it is never read as a catalog key.
        Text(verbatim: resolution.subtitle)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        controller.downloads.closeDialog()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(theme.surface.muted.color)
          .frame(width: 24, height: 24)
          .background(theme.surface.hover.color, in: Circle())
      }
      .buttonStyle(.plain)
      .help(L("Close without removing this download"))
      .accessibilityLabel(Text(verbatim: L("Close without removing this download")))
      .accessibilityIdentifier("download-dialog-close")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  // MARK: Stages

  @ViewBuilder
  private func stageBody(session: DownloadsModel.Session, resolution: DownloadDialogResolution)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      // A rejected action reads inside the dialog as well as in the banner behind it.
      if let message = session.errorMessage {
        DownloadNotice(kind: .error, text: message)
      }
      switch resolution.stage {
      case .setup:
        DownloadSetupStage()
      case .account:
        DownloadAccountStage(session: session, focus: $focus)
      case .resources:
        DownloadResourcesStage()
      case .auth:
        if let job = resolution.job {
          DownloadAuthStage(session: session, job: job, response: $response, focus: $focus)
        }
      case .started:
        if let job = resolution.job { DownloadStartedStage(resolution: resolution, job: job) }
      }
    }
  }
}
