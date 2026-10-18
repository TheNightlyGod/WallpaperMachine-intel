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
        SetupStage()
      case .account:
        AccountStage(session: session, focus: $focus)
      case .resources:
        ResourcesStage()
      case .auth:
        if let job = resolution.job {
          AuthStage(session: session, job: job, response: $response, focus: $focus)
        }
      case .started:
        if let job = resolution.job { StartedStage(resolution: resolution, job: job) }
      }
    }
  }
}

// MARK: - Shared pieces

/// A row of buttons at the foot of a stage: what the person can do on the left, how they leave on
/// the right. When they do not fit side by side (a long translation, a stage with four buttons)
/// the two groups take a row each.
private struct DialogActions<Leading: View, Trailing: View>: View {
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        leading
        Spacer(minLength: 8)
        trailing
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) { leading }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          trailing
        }
      }
    }
    .buttonStyle(.panelSecondary)
  }
}

private extension View {
  /// A small muted paragraph, as the dialog's notes are.
  func dialogNote(_ color: Color) -> some View {
    font(.system(size: 11.5))
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

// MARK: - Setup

/// Install SteamCMD, or point at a copy that is already there.
private struct SetupStage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let setup = controller.steamSetup
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "SteamCMD is Valve’s download tool. Install it here, or point to a copy you already have. Installing it does not sign you in."
      )
      .font(.system(size: 13))
      .frame(maxWidth: .infinity, alignment: .leading)
      statusLine(setup)
      if setup.isBusy {
        // An unknown total is a bar that is not filled, never 0%.
        ProgressView(value: setup.progress)
          .progressViewStyle(.linear)
          .accessibilityLabel(Text("SteamCMD installation progress"))
      }
      if let detail = setup.errorDetail {
        DownloadNotice(kind: .error, text: detail)
      }
      if let path = setup.candidatePath {
        if setup.canApprove {
          DownloadNotice(
            kind: .info, text: L("This downloaded copy needs your approval before it can run:"),
            detail: path)
        } else {
          DownloadNotice(
            kind: .warning, text: L("A downloaded copy is retained but not usable yet:"),
            detail: path)
        }
      }
      DialogActions {
        Button {
          controller.downloads.locateSteamCMD()
        } label: {
          Label("Locate a copy", systemImage: "folder")
        }
        .disabled(setup.isBusy)
        if setup.isBusy && setup.canCancel {
          Button("Cancel setup") { controller.downloads.cancelSteamCMDSetup() }
        }
      } trailing: {
        Button("Not now") { controller.downloads.closeDialog() }
          .keyboardShortcut(.cancelAction)
        primary(setup)
      }
      if setup.candidatePath != nil {
        HStack(spacing: 14) {
          Button("Show it in Finder") { controller.downloads.revealSteamCMDCandidate() }
          Button("Discard it") { controller.downloads.discardSteamCMDCandidate() }
          .disabled(setup.isBusy)
        }
        .buttonStyle(.panelLink)
        .font(.system(size: 12))
      }
      Text("Approval applies only to the exact copy you allow. Gatekeeper and signature checks stay in force.")
        .dialogNote(theme.surface.muted.color)
    }
  }

  @ViewBuilder
  private func statusLine(_ setup: SteamSetupState) -> some View {
    // While SteamCMD is being set up native says what it is doing ("Downloading SteamCMD…"); at
    // rest the line says whether it is there.
    let state = controller.workshop.steamCMDSetup.state
    HStack(spacing: 6) {
      Image(systemName: setup.isReady ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(setup.isReady ? theme.surface.approved.color : theme.surface.muted.color)
        .accessibilityHidden(true)
      switch state {
      case .ready: Text("SteamCMD is ready.")
      case .idle: Text("SteamCMD is not installed yet.")
      default: Text(verbatim: setup.status)
      }
    }
    .font(.system(size: 12.5, weight: .medium))
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
  }

  @ViewBuilder
  private func primary(_ setup: SteamSetupState) -> some View {
    if setup.canApprove {
      Button {
        controller.downloads.approveSteamCMD()
      } label: {
        Label("Allow this SteamCMD", systemImage: "checkmark.shield")
      }
      .buttonStyle(.panelPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(setup.isBusy)
    } else {
      Button {
        controller.downloads.installSteamCMD()
      } label: {
        if setup.errorDetail != nil {
          Label("Try again", systemImage: "arrow.clockwise")
        } else {
          Label("Install SteamCMD", systemImage: "arrow.down.circle")
        }
      }
      .buttonStyle(.panelPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(setup.isBusy)
    }
  }
}

// MARK: - Account

/// The Steam account name, and whether to stay signed in on this Mac.
private struct AccountStage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Bindable var session: DownloadsModel.Session
  var focus: FocusState<DownloadDialogView.Field?>.Binding

  var body: some View {
    let working = controller.isBusy(
      PanelActionCoordinator.key("continueDownload", id: session.target))
    let trimmed = session.account.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Steam account name")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.surface.muted.color)
        TextField(text: $session.account, prompt: Text(verbatim: "")) { Text("Steam account name") }
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .textContentType(.username)
          .autocorrectionDisabled()
          .focused(focus, equals: .account)
          .disabled(working)
          .accessibilityLabel(Text("Steam account name"))
          .onSubmit {
            if !trimmed.isEmpty && !working {
              controller.downloads.continueDownload(includeResources: false)
            }
          }
      }
      Toggle("Keep me signed in on this Mac", isOn: $session.remembersSession)
        .toggleStyle(.checkbox)
        .disabled(working)
      if let saved = controller.steamAccount.saved {
        let reused = trimmed.caseInsensitiveCompare(saved.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        Group {
          if reused {
            Text("Saved sign-in on this Mac: \(saved) · will be reused")
          } else {
            Text("Saved sign-in on this Mac: \(saved)")
          }
        }
        .dialogNote(theme.surface.muted.color)
      }
      DialogActions {
        EmptyView()
      } trailing: {
        Button("Not now") { controller.downloads.closeDialog() }
          .keyboardShortcut(.cancelAction)
        Button {
          controller.downloads.continueDownload(includeResources: false)
        } label: {
          Label("Continue", systemImage: "chevron.right")
        }
        .buttonStyle(.panelPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(working || trimmed.isEmpty)
      }
      Text("Your password and any Steam Guard code come next. This app never saves them.")
        .dialogNote(theme.surface.muted.color)
    }
  }
}

// MARK: - Resources

/// The shared scene resources: download them from Steam, or use a Wallpaper Engine that is already
/// installed. Each path is one button that carries its title and the one fact that decides it.
private struct ResourcesStage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.downloads
    let target = model.target ?? WorkshopStore.sceneAssetsRequestID
    let working = controller.isBusy(PanelActionCoordinator.key("continueDownload", id: target))
    VStack(alignment: .leading, spacing: 12) {
      if controller.workshop.sceneAssetsReady {
        Label {
          Text("Shared resources are already installed. Downloading again replaces them.")
        } icon: {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.surface.approved.color)
        }
        .font(.system(size: 13))
        .accessibilityAddTraits(.updatesFrequently)
      } else {
        Text("Scene wallpapers need shaders and materials from Wallpaper Engine. This is a one-time setup.")
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let warning = controller.workshop.sceneAssetsFailure {
        DownloadNotice(kind: .warning, text: warning)
      }
      VStack(spacing: 8) {
        ChoiceButton(
          systemImage: "arrow.down.circle", isEnabled: !working,
          action: { model.continueDownload(includeResources: true) }
        ) {
          Text("Download from Steam")
        } note: {
          Text("Needs a Steam account that owns Wallpaper Engine and several gigabytes free while downloading.")
        }
        ChoiceButton(
          systemImage: "folder", isEnabled: !controller.steamSetup.isBusy,
          action: { model.locateSceneAssets() }
        ) {
          Text("Use an existing installation")
        } note: {
          Text("Already have Wallpaper Engine installed? Choose its folder instead of downloading.")
        }
      }
      DialogActions {
        EmptyView()
      } trailing: {
        Button("Not now") { model.closeDialog() }
          .keyboardShortcut(.cancelAction)
      }
    }
  }
}

/// One of two ways forward: a symbol, what it is, the one thing to know, and a chevron.
private struct ChoiceButton<Title: View, Note: View>: View {
  let systemImage: String
  let isEnabled: Bool
  let action: () -> Void
  @ViewBuilder var title: Title
  @ViewBuilder var note: Note

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(theme.accent.accent.color)
          .frame(width: 34, height: 34)
          .background(
            theme.accent.accent.color.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          title.font(.system(size: 13, weight: .semibold))
          note
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.surface.faint.color)
      }
      .padding(10)
      .background(
        isHovering && isEnabled ? theme.surface.raisedHover.color : theme.surface.card.color,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.5)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Auth

/// Steam is signing in: connecting, then a password, a Steam Guard code or an approval on a phone.
private struct AuthStage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Bindable var session: DownloadsModel.Session
  let job: DownloadRow
  @Binding var response: String
  var focus: FocusState<DownloadDialogView.Field?>.Binding

  var body: some View {
    let model = controller.downloads
    let account = job.account.isEmpty ? session.account : job.account
    let waiting = job.prompt == nil && job.challenge == nil
    let guide = SteamGuardGuide.guide(for: job)
    VStack(alignment: .leading, spacing: 12) {
      identity(account: account, model: model)
      if waiting {
        SteamGuideCard(
          systemImage: "person.badge.key", title: job.status,
          note: L("Contacting Steam. Password and Steam Guard prompts appear here.")
        ) {
          ProgressView()
            .progressViewStyle(.linear)
            .accessibilityLabel(Text("Connecting to Steam"))
        }
      } else if let guide {
        SteamSignInGuideView(guide: guide, account: account)
        helpLink(guide.help)
      }
      if let error = job.errorMessage, !error.isEmpty {
        DownloadNotice(kind: .error, text: error)
      }
      if let warning = job.warning, !warning.isEmpty {
        DownloadNotice(kind: .warning, text: warning)
      }
      // One row of buttons: the prompt's own when Steam asks for an answer, else this one.
      if let prompt = job.prompt {
        promptForm(prompt)
      } else {
        DialogActions {
          cancelButton(model)
        } trailing: {
          Button("Not now") { model.closeDialog() }
            .keyboardShortcut(.cancelAction)
        }
      }
      Text("Only approve sign-ins you started yourself. Never share your password or recovery codes.")
        .dialogNote(theme.surface.muted.color)
    }
  }

  private func identity(account: String, model: DownloadsModel) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "person.circle")
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityHidden(true)
      // The account name is what the person typed, so it is never read as a catalog key.
      Text(
        "Signing in as \(Text(verbatim: account.isEmpty ? L("an unnamed account") : account).fontWeight(.semibold))"
      )
      .font(.system(size: 12.5))
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer(minLength: 8)
      Button("Change account") { model.changeAccount(forJob: job.id) }
        .buttonStyle(.panelLink)
        .font(.system(size: 12))
    }
  }

  /// **Cancel this download**, which leads the stage's one row of buttons.
  private func cancelButton(_ model: DownloadsModel) -> some View {
    Button("Cancel this download") { model.cancelFromDialog(job.id) }
  }

  /// The answer Steam asks for: a password, hidden, or a code, shown; under it the stage's buttons,
  /// with cancelling the download leading and Not now and Submit trailing.
  private func promptForm(_ prompt: WorkshopDownloader.Prompt) -> some View {
    let working = controller.isBusy(PanelActionCoordinator.key("downloadInput", id: job.id))
    let secret = job.promptIsSecret
    return VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 6) {
        // Steam's own words ("Steam password", "Steam Guard code"), translated at run time.
        Text(verbatim: PanelLocale.shared.catalogString(prompt.rawValue))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.surface.muted.color)
        Group {
          // Steam's own words ("Steam password", "Steam Guard code"), translated at run time.
          let label = Text(verbatim: PanelLocale.shared.catalogString(prompt.rawValue))
          // The label sits above the field; the field itself shows no second copy of it.
          if secret {
            SecureField(text: $response, prompt: Text(verbatim: "")) { label }
          } else {
            TextField(text: $response, prompt: Text(verbatim: "")) { label }.autocorrectionDisabled()
          }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .focused(focus, equals: .response)
        .disabled(working)
        .accessibilityLabel(Text(verbatim: PanelLocale.shared.catalogString(prompt.rawValue)))
        .onSubmit(submit)
      }
      DialogActions {
        cancelButton(controller.downloads)
      } trailing: {
        Button("Not now") { controller.downloads.closeDialog() }
          .keyboardShortcut(.cancelAction)
        Button(action: submit) {
          Label("Submit", systemImage: secret ? "lock" : "key")
        }
        .buttonStyle(.panelPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(working || response.isEmpty)
      }
    }
  }

  /// The secret is read here, the field is cleared at once, and the value goes straight to the job.
  private func submit() {
    let secret = response
    guard !secret.isEmpty else { return }
    response = ""
    controller.downloads.submitSecret(secret, toJob: job.id)
  }

  private func helpLink(_ help: SteamGuardGuide.Help) -> some View {
    Button {
      ExternalLink.open(help.url)
    } label: {
      Label {
        Text(verbatim: help.title)
      } icon: {
        Image(systemName: "arrow.up.right.square")
      }
    }
    .buttonStyle(.panelLink)
    .font(.system(size: 12))
  }
}

// MARK: - Started

/// The sign-in is done and the download is under way: the dialog says so, with live progress, and
/// steps aside by itself after a few seconds.
private struct StartedStage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  let resolution: DownloadDialogResolution
  let job: DownloadRow

  var body: some View {
    let model = controller.downloads
    let shared = job.id != resolution.subjectID
    let subject = resolution.subjectTitle
    VStack(alignment: .leading, spacing: 12) {
      SteamGuideCard(
        systemImage: "checkmark.circle", title: title(shared: shared, subject: subject),
        note: note(shared: shared, subject: subject)
      ) {
        VStack(alignment: .leading, spacing: 6) {
          if !job.status.isEmpty {
            Text(verbatim: job.status)
              .font(.system(size: 12))
              .foregroundStyle(theme.surface.muted.color)
              .accessibilityAddTraits(.updatesFrequently)
          }
          if let progress = job.clampedProgress {
            ProgressView(value: progress)
              .progressViewStyle(.linear)
              .accessibilityLabel(Text("Download progress"))
          } else {
            ProgressView()
              .progressViewStyle(.linear)
              .accessibilityLabel(Text("Download in progress"))
          }
        }
      }
      DialogActions {
        Button {
          model.showDownloadsFromDialog()
        } label: {
          Label("Show downloads", systemImage: "arrow.down.circle")
        }
      } trailing: {
        Button {
          model.closeDialog()
        } label: {
          Label("Done", systemImage: "checkmark")
        }
        .buttonStyle(.panelPrimary)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func title(shared: Bool, subject: String) -> String {
    if job.isSignInOnly { return L("Signed in to Steam") }
    return shared
      ? L("Signed in. Shared resources are downloading first")
      : L("Signed in. \(subject) is downloading")
  }

  private func note(shared: Bool, subject: String) -> String {
    if job.isSignInOnly { return L("Downloads will use this sign-in.") }
    return shared
      ? L("\(subject) starts automatically once they are installed. You can keep using the app meanwhile.")
      : L("You can keep using the app. Progress shows on the wallpaper and in the downloads list.")
  }
}
