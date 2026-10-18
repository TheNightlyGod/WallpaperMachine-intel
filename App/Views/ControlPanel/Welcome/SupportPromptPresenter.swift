import Foundation
import Observation

/// What can hold a one-time prompt back. A prompt is a courtesy: the first-run guide, anything else
/// that is modal, a wallpaper being switched and Steam or pixiv asking for a sign-in all come first,
/// and it resumes by itself when they are done.
struct SupportPromptGate: Equatable {
  /// The panel's window is on screen: visible, not minimised, not covered.
  var windowIsVisible = false
  var welcomeIsOpen = false
  /// A popover of the shell or a page is open.
  var popoverIsOpen = false
  var downloadDialogIsOpen = false
  /// A wallpaper switch is running or waiting.
  var switchIsInProgress = false
  var pixivIsSigningIn = false
  /// A download job is signing in or waits for a password or a Steam Guard answer.
  var downloadAwaitsSteam = false

  var allowsPresentation: Bool {
    windowIsVisible && !welcomeIsOpen && !popoverIsOpen && !downloadDialogIsOpen
      && !switchIsInProgress && !pixivIsSigningIn && !downloadAwaitsSteam
  }
}

/// The part of the download dialog's state the support offer reads, which `DownloadsModel` answers
/// with its own `isDialogOpen`. There is deliberately no default: a renamed property must break the
/// build, not leave the offer free to cover an open dialog.
@MainActor
protocol DownloadDialogState: AnyObject {
  var isDialogOpen: Bool { get }
}

extension DownloadsModel: DownloadDialogState {}

/// When a one-time prompt may be on screen and what its buttons do.
///
/// Whether there is a prompt, and which, is the store's (`SupportPromptStore`, through
/// `PanelController.pendingPrompt`). Whether it may appear now is the gate's. Once the sheet has
/// been seen that prompt is spent for good, so the presenter keeps that one presentation: when the
/// guide, a popover or a sign-in takes the window it closes the sheet without dismissing it and
/// brings the same sheet back afterwards. A deliberate choice, **Not now** or Escape ends it, and no
/// other prompt follows in this window (the store allows one a day).
@MainActor
@Observable
final class SupportPromptPresenter {
  unowned let controller: PanelController

  /// The prompt this window put on screen, once it was seen: the store counts it as spent.
  private(set) var presented: SupportPromptStore.Prompt?
  /// The person answered or left; no prompt returns in this window.
  private(set) var isDismissed = false
  /// A link choice is being opened.
  private(set) var isChoosing = false
  /// Why the last link choice failed.
  private(set) var error: String?

  init(controller: PanelController) { self.controller = controller }

  /// The prompt was on screen at least once.
  var hasBeenShown: Bool { presented != nil }

  /// The prompt the sheet shows: the one already seen, or the one waiting.
  var prompt: SupportPromptStore.Prompt? { presented ?? controller.pendingPrompt }

  /// What holds the offer back now; every input is read from observable state, so a view that asks
  /// is asked again when one changes.
  var gate: SupportPromptGate {
    let downloads: any DownloadDialogState = controller.downloads
    return SupportPromptGate(
      windowIsVisible: controller.presentation.isVisible,
      welcomeIsOpen: controller.shell.isWelcomeOpen,
      popoverIsOpen: controller.shell.isPopoverOpen,
      downloadDialogIsOpen: downloads.isDialogOpen,
      switchIsInProgress: controller.supportPromptDeferredBySwitch,
      pixivIsSigningIn: controller.pixivAccount.isSigningIn,
      downloadAwaitsSteam: controller.steamDownloadRows.contains {
        $0.isPending && ($0.isAuthenticating || $0.prompt != nil || $0.challenge != nil)
      })
  }

  var canPresent: Bool { gate.allowsPresentation }

  /// Whether the sheet should be up: a prompt is waiting, or one that was already shown is
  /// interrupted, and nothing holds it back.
  var wantsPresentation: Bool {
    guard !isDismissed else { return false }
    return (hasBeenShown || controller.supportPromptPending) && canPresent
  }

  /// The sheet is on screen. The first time, its prompt is spent. A sheet of a window nobody can see
  /// is not shown, so it spends nothing and counts as not yet seen.
  func sheetDidAppear() {
    guard !hasBeenShown, controller.presentation.isVisible, let prompt = controller.pendingPrompt
    else { return }
    presented = prompt
    controller.supportPromptShown(prompt)
  }

  /// **Star on GitHub**, **Become a Supporter** and **Send performance data**. A link that cannot be
  /// opened keeps the prompt open with the reason, so the other row, a retry and **Not now** all
  /// remain.
  func choose(_ choice: SupportPromptChoice) async {
    guard !isDismissed, !isChoosing, let prompt else { return }
    if choice == .dismiss {
      dismiss()
      return
    }
    isChoosing = true
    error = nil
    defer { isChoosing = false }
    do {
      try await controller.supportPromptChoice(choice, for: prompt)
      isDismissed = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// **What is sent** on the performance data question: the document on GitHub, without closing
  /// the sheet. A link that cannot be opened says so in the sheet.
  func showPerformanceDataDetails() {
    error = nil
    do {
      try controller.openPerformanceDataDetails()
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// **Not now**, the close button and Escape. Leaving is always available, so the sheet goes first
  /// and spending the prompt follows, whatever that does.
  @discardableResult
  func dismiss() -> Task<Void, Never> {
    let prompt = prompt ?? .support
    isDismissed = true
    return Task { [controller] in try? await controller.supportPromptChoice(.dismiss, for: prompt) }
  }
}
