import SwiftUI

/// The fields of the Steam page that can hold keyboard focus.
enum SteamField: Hashable { case account, password, response }

/// Page two: sign in to Steam now, or leave it for the first download. One of five states shows,
/// by `SteamSignInPhase`: signed in (with what the ownership check found), waiting for SteamCMD, the
/// form, or the sign-in running with whatever Steam is asking. Signed in, unless the account is
/// known not to own Wallpaper Engine, it also offers to import the account's subscriptions.
struct WelcomeSteamPage: View {
  @Environment(FirstRunModel.self) private var model
  @Environment(\.welcomeIsCompact) private var compact
  @FocusState private var focus: SteamField?

  var body: some View {
    let phase = model.phase
    WelcomeColumn(spacing: compact ? 16 : 20) {
      WelcomePageHeader(
        title: Text("Sign in to Steam"),
        lead: Text(
          "You can browse without an account. Steam Workshop downloads require an account that owns Wallpaper Engine. Sign in now, or skip and sign in at your first download."
        ))
      state(of: phase)
      if case .signedIn(_, let ownership, _) = phase.state, ownership != .notOwned {
        WelcomeSubscriptionsCard()
      }
      if !phase.isSignedIn { WelcomeSteamLinks() }
    }
    // The status card is the page's live status: a change is announced after whatever VoiceOver
    // is reading. The form's failures announce themselves.
    .onChange(of: model.steamStatus) { _, status in
      if let status { model.announce(status) }
    }
    .onChange(of: transition(of: phase)) {
      // Focus moves only when it has nowhere to be, never over what the person put it on.
      let target = model.steamFocusTarget()
      guard focus == nil, let target else { return }
      switch target {
      case .response: focusLater(.response)
      case .password: focusLater(.password)
      case .continueButton: model.requestContinueFocus()
      case .title: model.requestTitleFocus()
      }
    }
  }

  /// Everything the focus rule reads, so it is asked exactly when one of them moves.
  private func transition(of phase: SteamSignInPhase) -> SteamFocusTarget.Key {
    SteamFocusTarget.Key(
      job: model.signInJob, request: model.signInRequest, signedInAccount: phase.signedInAccount,
      pageError: model.error)
  }

  private func focusLater(_ field: SteamField) {
    Task { @MainActor in focus = field }
  }

  @ViewBuilder private func state(of phase: SteamSignInPhase) -> some View {
    switch phase.state {
    case .signedIn(let account, let ownership, let warning):
      WelcomeSignedInCard(account: account, ownership: ownership, warning: warning)
    case .setup(let request):
      WelcomeSetupCard(request: request)
    case .form(let failure):
      WelcomeSignInForm(jobFailure: failure, focus: $focus)
    case .signingIn(let signingIn):
      WelcomeSigningIn(signingIn: signingIn, focus: $focus)
    }
  }
}

// MARK: - Links

/// Where to get an account and the app.
struct WelcomeSteamLinks: View {
  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      column(
        Text("No Steam account yet?"), Text("Creating one is free."),
        link: WelcomeLinkButton(title: Text("Create a Steam account"), url: ExternalLink.steamJoin))
      column(
        Text("Don’t own Wallpaper Engine?"), Text("It is a one-time purchase on Steam."),
        link: WelcomeLinkButton(
          title: Text("Buy Wallpaper Engine"), url: ExternalLink.wallpaperEngineStore))
    }
  }

  private func column(_ title: Text, _ detail: Text, link: WelcomeLinkButton) -> some View {
    WelcomeColumn(spacing: 3) {
      title.font(.system(size: 12, weight: .semibold))
      detail.font(.system(size: 12)).foregroundStyle(.secondary)
      link.padding(.top, 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Signed in

/// The account is signed in. What the license check found decides the words and what is offered;
/// Continue is never held back, because the check is advisory and Steam authorizes each download.
struct WelcomeSignedInCard: View {
  let account: String
  let ownership: WorkshopDownloader.WallpaperEngineOwnership
  let warning: String?

  @Environment(FirstRunModel.self) private var model

  var body: some View {
    let notice = OwnershipNotice(ownership: ownership)
    WelcomeStatusCard(
      systemImage: notice.symbol, title: Text("Signed in as \(account)"),
      detail: Text(verbatim: notice.message), isSuccess: notice.isSuccess
    ) {
      WelcomeColumn(spacing: 10) {
        if let warning { WelcomeNotice(style: .warning, message: warning) }
        TagFlow(spacing: 8) {
          if notice.offersPurchase {
            Button {
              ExternalLink.open(ExternalLink.wallpaperEngineStore)
            } label: {
              Label("Buy Wallpaper Engine", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.welcomePrimary(size: .compact))
          }
          if notice.offersRecheck {
            Button("Check ownership again") { Task { await model.checkOwnership() } }
              .buttonStyle(.welcomeCapsule)
              .disabled(model.pending.contains(.signIn))
          }
          Button("Use a different account") { Task { await model.useDifferentAccount() } }
            .buttonStyle(.welcomeCapsule)
            .disabled(model.pending.contains(.signOut))
        }
        if let error = model.error { WelcomeNotice(style: .error, message: error) }
      }
    }
  }
}

// MARK: - Subscriptions

/// **Import my subscriptions**: the Workshop wallpapers the account already subscribes to on Steam,
/// downloaded into the library. Steam lists them only behind its own Steam Community sign-in, so a
/// first import opens Steam's sign-in window; this Mac then stays signed in. The downloads run
/// behind the guide, in Downloads.
struct WelcomeSubscriptionsCard: View {
  @Environment(FirstRunModel.self) private var model

  var body: some View {
    let isImporting = model.pending.contains(.subscriptions)
    WelcomeColumn(spacing: 8) {
      WelcomeActionRow(
        symbol: "square.and.arrow.down.on.square", color: .blue,
        title: Text("Import my subscriptions"), note: note(isImporting: isImporting),
        trailingSymbol: "chevron.right"
      ) { Task { await model.importSubscriptions() } }
      .disabled(isImporting)
      switch model.subscriptionImport {
      case .queued(let count):
        WelcomeNotice(style: .info, message: L("Subscribed wallpapers added to Downloads: \(count)"))
      case .upToDate:
        WelcomeNotice(
          style: .info, message: L("Every wallpaper you subscribe to is already in your library."))
      case nil:
        EmptyView()
      }
    }
    // Shown here, the offer needs no one-time prompt later.
    .onAppear { model.subscriptionsOffered() }
  }

  private func note(isImporting: Bool) -> Text {
    if isImporting { return Text("Waiting for Steam") }
    if model.isSignedInToSteamCommunity {
      return Text("Download the Workshop wallpapers you already subscribe to on Steam into your library.")
    }
    return Text(
      "Download the Workshop wallpapers you already subscribe to on Steam. Steam asks you to sign in to Steam Community once, on its own page."
    )
  }
}

// MARK: - SteamCMD

/// The sign-in waits for SteamCMD, which is installing, or needs approval, or failed.
struct WelcomeSetupCard: View {
  let request: DownloadRequestRow
  @Environment(FirstRunModel.self) private var model

  /// What the sentence under the title says, which must match what the card offers: an install
  /// in progress only while one runs.
  enum Detail: Equatable {
    /// The retained copy waits for the person's approval.
    case approval
    /// The install runs; the sign-in follows on its own.
    case installing
    /// Nothing runs: install it or locate a copy, and the sign-in follows.
    case installOrLocate

    /// Nil after a failure: the error notice says what went wrong, beside Try again and Locate a
    /// copy.
    static func make(isBusy: Bool, canApprove: Bool, hasError: Bool) -> Detail? {
      if canApprove { return .approval }
      if isBusy { return .installing }
      return hasError ? nil : .installOrLocate
    }
  }

  var body: some View {
    let setup = model.setup
    WelcomeStatusCard(
      systemImage: "arrow.down.circle", title: Text(verbatim: setup.status),
      detail: detailText(
        .make(isBusy: setup.isBusy, canApprove: setup.canApprove, hasError: setup.errorDetail != nil)),
      working: setup.isBusy
        ? WelcomeWorking(
          fraction: setup.progress, label: L("SteamCMD installation progress")) : nil
    ) {
      WelcomeColumn(spacing: 10) {
        if setup.isBusy, let progress = setup.progress {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            // The card's ring already reads as this progress, under the same name.
            .accessibilityHidden(true)
        }
        if let detail = setup.errorDetail { WelcomeNotice(style: .error, message: detail) }
        TagFlow(spacing: 8) {
          if setup.canApprove {
            Button { Task { await model.approveSteamCMD() } } label: {
              Label("Allow this SteamCMD", systemImage: "checkmark.shield")
            }
            .buttonStyle(.welcomePrimary(size: .compact))
          } else if !setup.isBusy {
            Button { Task { await model.installSteamCMD() } } label: {
              if setup.errorDetail != nil {
                Label("Try again", systemImage: "arrow.clockwise")
              } else {
                Label("Install SteamCMD", systemImage: "arrow.down.circle")
              }
            }
            .buttonStyle(.welcomePrimary(size: .compact))
            Button { Task { await model.locateSteamCMD() } } label: {
              Label("Locate a copy", systemImage: "folder")
            }
            .buttonStyle(.welcomeCapsule)
          }
          WelcomeCancelButton()
        }
      }
    }
  }

  private func detailText(_ detail: Detail?) -> Text? {
    switch detail {
    case .approval:
      Text("macOS needs your approval before this downloaded copy of SteamCMD can run. Only this exact copy is allowed.")
    case .installing:
      Text("SteamCMD is Valve’s free download tool. It is being installed into this app’s own folder; the sign-in follows on its own.")
    case .installOrLocate:
      Text("SteamCMD is Valve’s free download tool. Install it into this app’s own folder or locate a copy you already have; the sign-in follows on its own.")
    case nil:
      nil
    }
  }
}

/// **Cancel** of whatever the sign-in is doing.
struct WelcomeCancelButton: View {
  @Environment(FirstRunModel.self) private var model

  var body: some View {
    Button("Cancel") { Task { await model.cancelSignIn() } }
      .buttonStyle(.welcomeCapsule)
      .disabled(model.pending.contains(.cancel))
  }
}

// MARK: - The form

/// The account name and password, and what to keep. The password is typed here and goes no further
/// than Steam's prompt: this view keeps it, clears it the moment **Sign in** hands it over, and
/// hands the model a copy that is held only until Steam asks.
struct WelcomeSignInForm: View {
  let jobFailure: SteamSignInPhase.JobFailure?
  var focus: FocusState<SteamField?>.Binding

  @Environment(FirstRunModel.self) private var model
  @Environment(\.panelTheme) private var theme
  @State private var password = ""

  var body: some View {
    @Bindable var model = model
    let working = model.pending.contains(.signIn)
    WelcomeColumn(spacing: 14) {
      field(label: Text("Steam account name"), note: Text("Your login name, not the profile name other players see.")) {
        TextField(text: $model.signInAccount, prompt: Text("The name you log in with")) {
          Text("Steam account name")
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .autocorrectionDisabled()
        .focused(focus, equals: .account)
        .onSubmit { focus.wrappedValue = .password }
      }
      field(label: Text("Password"), note: nil) {
        passwordField
      }
      Toggle(isOn: $model.remembersSession) {
        WelcomeColumn(spacing: 2) {
          Text("Keep me signed in on this Mac").font(.system(size: 13))
          Text("Keeps you signed in to Steam on this Mac so downloads don’t ask again. Your password is not saved.")
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      .toggleStyle(.checkbox)
      if let failure { WelcomeNotice(style: .error, message: failure) }
      HStack {
        Button(action: submit) {
          Label {
            if model.setup.isReady {
              Text("Sign in")
            } else {
              Text("Install SteamCMD and sign in")
            }
          } icon: {
            Image(systemName: "person.badge.key")
          }
        }
        .buttonStyle(.welcomePrimary)
        .keyboardShortcut(.defaultAction)
        Spacer(minLength: 0)
      }
      WelcomeNote(
        text: model.setup.isReady
          ? Text("Your password goes straight to Valve’s SteamCMD and is never stored by this app. Steam Guard requests appear here.")
          : Text("SteamCMD is Valve’s free download tool. It is installed into this app’s own folder the first time. Your password goes straight to it and is never stored by this app."))
    }
    .disabled(working)
    .padding(16)
    .welcomeSurface()
    .onAppear { focus.wrappedValue = failure == nil ? .account : .password }
  }

  /// What the page says went wrong: its own message, else the last attempt's.
  private var failure: String? {
    if let error = model.error { return error }
    switch jobFailure {
    case .message(let message): return message
    case .cancelled: return L("The sign-in was cancelled.")
    case nil: return nil
    }
  }

  private func field<Field: View>(label: Text, note: Text?, @ViewBuilder _ field: () -> Field)
    -> some View
  {
    WelcomeColumn(spacing: 5) {
      label.font(.system(size: 12, weight: .semibold))
      field()
      if let note {
        note.font(.system(size: 12)).foregroundStyle(theme.surface.muted.color)
      }
    }
  }

  private var passwordField: some View {
    Group {
      // Swapping one kind of field for the other keeps the text: both are bound to `password`.
      if model.revealsPassword {
        TextField(text: $password) { Text("Password") }
      } else {
        SecureField(text: $password) { Text("Password") }
      }
    }
    .labelsHidden()
    .textFieldStyle(.roundedBorder)
        .controlSize(.large)
    .autocorrectionDisabled()
    .focused(focus, equals: .password)
    .onSubmit(submit)
    .padding(.trailing, 0)
    .overlay(alignment: .trailing) {
      Button {
        model.revealsPassword.toggle()
        // The field is swapped for the other kind, which does not keep the cursor.
        Task { @MainActor in focus.wrappedValue = .password }
      } label: {
        Image(systemName: model.revealsPassword ? "eye.slash" : "eye")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .frame(width: 26, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(model.revealsPassword ? L("Hide password") : L("Show password"))
      .accessibilityLabel(model.revealsPassword ? L("Hide password") : L("Show password"))
      .padding(.trailing, 2)
    }
  }

  private func submit() {
    if let problem = model.validateSignIn(password: password) {
      focus.wrappedValue = problem == .invalidAccount ? .account : .password
      return
    }
    // The field is emptied before anything is sent: the password lives on only as the model's one
    // held copy, until Steam asks for it.
    let secret = password
    password = ""
    Task { await model.submitSignIn(password: secret) }
  }
}

// MARK: - Signing in

/// The sign-in is running: what Steam says, what it asks, and a way out.
struct WelcomeSigningIn: View {
  let signingIn: SteamSignInPhase.SigningIn
  var focus: FocusState<SteamField?>.Binding

  @Environment(FirstRunModel.self) private var model

  var body: some View {
    switch signingIn {
    case .checkingOwnership:
      WelcomeStatusCard(
        systemImage: "magnifyingglass", title: Text("Checking Wallpaper Engine ownership…"),
        working: .indeterminate(L("Checking Wallpaper Engine ownership…"))
      ) { WelcomeCancelButton() }
    case .queued(let status):
      WelcomeStatusCard(
        systemImage: "person.badge.key", title: Text(verbatim: status),
        detail: Text("The sign-in starts as soon as the current download is done."),
        working: .indeterminate(L("Waiting"))
      ) { WelcomeCancelButton() }
    case .prompt(let job, let guide):
      WelcomeColumn(spacing: 14) {
        if let guide {
          WelcomeGuardCard(guide: guide, account: account(of: job), isWaiting: false)
        } else {
          WelcomeStatusCard(
            systemImage: "lock", title: Text("Steam asks for your password"),
            detail: Text("Enter it below. It goes straight to Steam and is never stored by this app."))
        }
        WelcomePromptForm(job: job, guide: guide, focus: focus)
      }
    case .challenge(let guide):
      WelcomeColumn(spacing: 12) {
        WelcomeGuardCard(guide: guide, account: account(of: model.signInJob), isWaiting: true)
        HStack(spacing: 12) {
          WelcomeCancelButton()
          WelcomeLinkButton(title: Text(verbatim: guide.help.title), url: guide.help.url)
        }
      }
    case .authenticating(let status):
      WelcomeStatusCard(
        systemImage: "person.badge.key",
        title: status.isEmpty ? Text("Contacting Steam…") : Text(verbatim: status),
        detail: Text("Password and Steam Guard prompts appear here."),
        working: .indeterminate(L("Connecting to Steam"))
      ) { WelcomeCancelButton() }
    }
  }

  /// The account the request is for: the job's, else what was typed.
  private func account(of job: DownloadRow?) -> String {
    let account = job?.account ?? ""
    return account.isEmpty ? model.signInAccount : account
  }
}

/// The answer to what Steam asks: the password when the guide holds none, or a Steam Guard code.
/// The field is a new one whenever Steam asks something else, and is emptied the moment the answer
/// goes: it belongs to Steam alone. Job updates that ask the same thing (progress, status) keep
/// what is being typed.
struct WelcomePromptForm: View {
  let job: DownloadRow
  let guide: SteamGuardGuide?
  var focus: FocusState<SteamField?>.Binding

  var body: some View {
    // The typed text is the inner view's state, and the inner view is identified by the question:
    // an `.id` inside a view would reset only its children, never the view's own state.
    WelcomePromptFields(job: job, guide: guide, focus: focus)
      .id(job.prompt?.rawValue)
  }
}

private struct WelcomePromptFields: View {
  let job: DownloadRow
  let guide: SteamGuardGuide?
  var focus: FocusState<SteamField?>.Binding

  @Environment(FirstRunModel.self) private var model
  @State private var response = ""

  var body: some View {
    let answering = model.isAnswering(job)
    let secure = job.promptIsSecret
    WelcomeColumn(spacing: 10) {
      if let prompt = job.prompt {
        Text(verbatim: PanelLocale.shared.catalogString(prompt.rawValue))
          .font(.system(size: 12, weight: .semibold))
      }
      Group {
        if secure {
          SecureField(text: $response) { Text(verbatim: promptName) }
        } else {
          TextField(text: $response) { Text(verbatim: promptName) }
        }
      }
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
        .controlSize(.large)
      .autocorrectionDisabled()
      .focused(focus, equals: .response)
      .onSubmit(submit)
      HStack(spacing: 8) {
        Button(action: submit) {
          Label("Submit", systemImage: secure ? "lock" : "key")
        }
        .buttonStyle(.welcomePrimary(size: .compact))
        .keyboardShortcut(.defaultAction)
        WelcomeCancelButton()
        if let guide {
          WelcomeLinkButton(title: Text(verbatim: guide.help.title), url: guide.help.url)
            .padding(.leading, 4)
        }
      }
    }
    .disabled(answering)
    .padding(16)
    .welcomeSurface()
    .onAppear { focus.wrappedValue = .response }
  }

  private var promptName: String {
    job.prompt.map { PanelLocale.shared.catalogString($0.rawValue) } ?? ""
  }

  private func submit() {
    guard !response.isEmpty else { return }
    let value = response
    response = ""
    model.submitResponse(value, toJob: job)
  }
}

// MARK: - Steam Guard

/// What to do on the phone or in the mailbox when Steam asks for more than a password: an icon, a
/// title, the numbered steps with the words to look for in bold, and a note.
struct WelcomeGuardCard: View {
  let guide: SteamGuardGuide
  let account: String
  /// Nothing to type: Steam waits for the approval.
  let isWaiting: Bool

  @Environment(\.panelTheme) private var theme

  var body: some View {
    WelcomeStatusCard(
      systemImage: symbol, title: Text(verbatim: guide.title),
      working: isWaiting ? .indeterminate(L("Waiting for Steam")) : nil
    ) {
      WelcomeColumn(spacing: 8) {
        ForEach(Array(guide.steps(account: account).enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(index + 1)")
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
              .foregroundStyle(theme.accent.onPrimary.color)
              .frame(width: 18, height: 18)
              .background(theme.accent.primary.color, in: Circle())
              .accessibilityHidden(true)
            Text(step)
              .font(.system(size: 12.5))
              .lineSpacing(2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
        }
        if let note = guide.note {
          Text(verbatim: note)
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
            .padding(.top, 2)
        }
      }
    }
  }

  private var symbol: String {
    switch guide {
    case .mobileApproval, .authenticatorCode: "iphone"
    case .emailCode: "envelope"
    case .unknown: "checkmark.shield"
    }
  }
}
