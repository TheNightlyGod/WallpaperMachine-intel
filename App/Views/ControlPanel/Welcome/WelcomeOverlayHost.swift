import SwiftUI

/// The first-run guide as a full-window overlay, and where the support prompt is presented as a
/// sheet. The root mounts it over the split view and, while `ShellModel.isWelcomeOpen`, disables
/// what is behind it and hides that from VoiceOver.
///
/// It is always mounted, and idle while the guide is closed: it reads the guide's flag and nothing
/// else until the guide opens, and the support sheet only when an offer exists.
struct WelcomeOverlayHost: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shell = controller.shell
    let model = controller.welcome
    let presenter = controller.supportPrompt
    let isOpen = shell.isWelcomeOpen
    // Read here, in the body, so the host is drawn again when the offer or what holds it moves.
    let wantsSupportPrompt = presenter.wantsPresentation
    ZStack {
      if isOpen {
        WelcomeGuide()
          .environment(model)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(isOpen)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isOpen)
    .onChange(of: isOpen, initial: true) { _, isOpen in
      if isOpen { model.open() } else { model.close() }
    }
    // A closing window takes the held password with it.
    .onDisappear { model.close() }
    // The Start page's Import wallpapers waits for the window to show Installed. The page change
    // reaches the root's `onChange` in this update or an earlier one, where it closes the popovers
    // of the page that was left; a task started from this `onChange` runs after all of them, so the
    // Import popover it opens stays open. (`.task(id:)` would start before them.)
    .onChange(of: model.importPopoverIsWaiting) { _, isWaiting in
      if isWaiting { Task { @MainActor in model.openWaitingImportPopover() } }
    }
    .sheet(
      isPresented: Binding(
        get: { wantsSupportPrompt },
        // The system closing it (Escape) is the person leaving; the presenter taking the window
        // for the guide, a popover or a sign-in is not, and never comes through here.
        set: { shown in if !shown && !presenter.isDismissed { presenter.dismiss() } })
    ) {
      SupportPromptSheet(presenter: presenter)
    }
  }
}

/// The one-time prompts, one at a time: after the first downloaded wallpaper, star the project or
/// become a supporter; later, a GitHub star; for someone who finished the guide before it offered
/// the switch, whether to send performance data; for someone signed in to Steam who never met the
/// import, importing their subscriptions. Links open only when chosen; nothing is starred or paid
/// by opening one. **Not now**, the close button and Escape all just leave.
struct SupportPromptSheet: View {
  let presenter: SupportPromptPresenter

  @Environment(\.panelTheme) private var theme

  var body: some View {
    let prompt = presenter.prompt ?? .support
    WelcomeColumn(spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        WelcomeColumn(spacing: 6) {
          // The prompt's words can be selected and copied; the labels of its buttons cannot, so
          // a click anywhere on a choice makes the choice.
          title(prompt)
            .font(.system(size: 19, weight: .bold))
            .tracking(-0.2)
            .accessibilityAddTraits(.isHeader)
            .textSelection(.enabled)
          lead(prompt)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(theme.surface.muted.color)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          presenter.dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.surface.muted.color)
            .frame(width: 22, height: 22)
            .background(theme.surface.hover.color, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(closeLabel(prompt))
        .accessibilityLabel(closeLabel(prompt))
      }
      WelcomeColumn(spacing: 8) { choices(prompt) }
        .disabled(presenter.isChoosing)
      if let error = presenter.error { WelcomeNotice(style: .error, message: error) }
      HStack {
        if prompt == .telemetry {
          Button {
            presenter.showPerformanceDataDetails()
          } label: {
            Label("What is sent", systemImage: "arrow.up.right")
          }
          .buttonStyle(.link)
          .disabled(presenter.isChoosing)
        }
        Spacer(minLength: 0)
        Button("Not now") { presenter.dismiss() }
          .buttonStyle(.welcomeCapsule)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 440)
    .foregroundStyle(theme.surface.text.color)
    .background(theme.surface.background.color)
    .onAppear { presenter.sheetDidAppear() }
  }

  private func title(_ prompt: SupportPromptStore.Prompt) -> Text {
    switch prompt {
    case .support: Text("Feeling good?")
    case .star: Text("Like WallpaperMachine?")
    case .telemetry: Text("Send performance data?")
    case .subscriptions: Text("Import your Steam subscriptions?")
    }
  }

  private func lead(_ prompt: SupportPromptStore.Prompt) -> Text {
    switch prompt {
    case .support:
      Text(
        "Your first downloaded wallpaper is up and running. Enjoying WallpaperMachine? You can help it grow."
      )
    case .star: Text("A star on GitHub helps other Mac users find it.")
    case .telemetry:
      Text(
        "It helps find what makes wallpapers slow: how long they take to apply, their frame rate and energy use, and your Mac’s model, sent once a day. No names, files or account details."
      )
    case .subscriptions:
      Text(
        "WallpaperMachine can download the Workshop wallpapers you already subscribe to on Steam. Sign in to Steam Community once, on Steam’s own page, and this Mac stays signed in until you sign out."
      )
    }
  }

  private func closeLabel(_ prompt: SupportPromptStore.Prompt) -> String {
    prompt == .support ? L("Dismiss support prompt") : L("Close")
  }

  @ViewBuilder
  private func choices(_ prompt: SupportPromptStore.Prompt) -> some View {
    switch prompt {
    case .support:
      WelcomeActionRow(
        symbol: "star", color: .orange, title: Text("Star on GitHub"),
        note: Text("Help others discover WallpaperMachine."), trailingSymbol: "arrow.up.right"
      ) { choose(.star) }
      WelcomeActionRow(
        symbol: "heart", color: theme.surface.heart.color, title: Text("Become a Supporter"),
        note: Text("Support development with a one-time contribution."),
        trailingSymbol: "arrow.up.right"
      ) { choose(.supporter) }
    case .star:
      WelcomeActionRow(
        symbol: "star", color: .orange, title: Text("Star on GitHub"),
        note: Text("Opens the project on GitHub."), trailingSymbol: "arrow.up.right"
      ) { choose(.star) }
    case .telemetry:
      // Turns a setting on; nothing opens.
      WelcomeActionRow(
        symbol: "waveform.path.ecg", color: .teal, title: Text("Send performance data"),
        note: Text("You can turn it off in Settings › Storage."), trailingSymbol: "checkmark"
      ) { choose(.enableTelemetry) }
    case .subscriptions:
      // Steam's sign-in window, then the downloads; the sheet closes at once.
      WelcomeActionRow(
        symbol: "square.and.arrow.down.on.square", color: .blue,
        title: Text("Import my subscriptions"),
        note: Text("Opens Steam’s sign-in, then adds them to Downloads."), trailingSymbol: "chevron.right"
      ) { choose(.importSubscriptions) }
    }
  }

  private func choose(_ choice: SupportPromptChoice) {
    Task { await presenter.choose(choice) }
  }
}
