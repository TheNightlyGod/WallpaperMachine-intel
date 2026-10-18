import Foundation

/// The card that tells a person which device to pick up and what to press when Steam asks for more
/// than a password: an icon, a one-line title and numbered steps, shared by the download dialog and
/// the first-run guide.
///
/// A plain password prompt needs no card: its labelled field says everything. Any other prompt
/// Steam makes without naming a method gets the general one.
enum SteamGuardGuide: Equatable {
  /// Steam sent a request to the phone's Steam app, which is approved there; nothing is typed.
  case mobileApproval
  /// The code the Steam app shows, typed here.
  case authenticatorCode
  /// The code Steam emailed, typed here.
  case emailCode
  /// A method this version does not know by name.
  case unknown

  /// The page the card links to for help with its method.
  enum Help: Equatable {
    case mobileApp, emailedCodes

    @MainActor var title: String {
      switch self {
      case .mobileApp: L("Get the Steam mobile app")
      case .emailedCodes: L("Help with emailed codes")
      }
    }

    var url: URL {
      switch self {
      case .mobileApp: ExternalLink.steamMobileApp
      case .emailedCodes: ExternalLink.steamEmailedCodeHelp
      }
    }
  }

  /// The card the job calls for: the one for its challenge, the general one for a prompt that is
  /// not the password, and none for the password or for a job that asks for nothing.
  static func guide(for job: DownloadRow) -> SteamGuardGuide? {
    switch job.challenge {
    case .mobileApproval: .mobileApproval
    case .authenticatorCode: .authenticatorCode
    case .emailCode: .emailCode
    case nil: job.prompt != nil && !job.promptIsSecret ? .unknown : nil
    }
  }

  /// Whether the answer is typed here. Approving on the phone needs no field.
  var asksForInput: Bool { self != .mobileApproval }

  var help: Help { self == .emailCode ? .emailedCodes : .mobileApp }

  @MainActor
  var title: String {
    switch self {
    case .mobileApproval: L("Approve the sign-in on your phone")
    case .authenticatorCode: L("Enter the code from the Steam app")
    case .emailCode: L("Enter the code Steam emailed you")
    case .unknown: L("Verify with the method Steam requested")
    }
  }

  /// The line under the steps; the general card has none.
  @MainActor
  var note: String? {
    switch self {
    case .mobileApproval:
      L("Only approve a request you just started. Deny anything you do not recognise.")
    case .authenticatorCode: L("Don’t share this code with anyone. Enter it only here.")
    case .emailCode: L("Steam never asks for your password by email. Enter the code only here.")
    case .unknown: nil
    }
  }

  /// The numbered steps, with the words a person must find on their phone in bold. `account` is
  /// the Steam account the request is for.
  @MainActor
  func steps(account: String) -> [AttributedString] {
    switch self {
    case .mobileApproval:
      let guardTab = L("Steam Guard")
      let who = account.isEmpty ? L("your account") : account
      let question = L("Where are you trying to sign in?")
      let client = L("Steam Client")
      return [
        Self.emphasized(
          L("Open the Steam app on your phone and tap \(guardTab), the shield tab at the bottom."),
          [guardTab]),
        Self.emphasized(L("A request to sign in as \(who) is waiting there. Approve it."), [who]),
        Self.emphasized(
          L(
            "If Steam asks \(question), choose \(client). This app signs in through Valve’s SteamCMD, which counts as the Steam client."
          ), [question, client]),
        AttributedString(L("Then come back here. The dialog continues once Steam confirms.")),
      ]
    case .authenticatorCode:
      let guardTab = L("Steam Guard")
      return [
        Self.emphasized(
          L("Open the Steam app on your phone and tap \(guardTab), the shield tab at the bottom."),
          [guardTab]),
        AttributedString(
          L("Read the five-character code shown at the top. It changes every 30 seconds.")),
        AttributedString(
          L("Type it below and submit before it changes. If it has already changed, use the new one.")),
      ]
    case .emailCode:
      return [
        AttributedString(
          L("Check the inbox of the email address registered to this Steam account. Look in spam or junk too.")),
        AttributedString(
          L("Open the newest Steam Guard message. Every sign-in attempt sends a fresh code, so older ones no longer work.")),
        AttributedString(L("Type the five-character code below and submit it.")),
      ]
    case .unknown:
      return [
        AttributedString(L("Follow the verification Steam asked for in its app or email, then continue here.")),
        AttributedString(L("Never disable Steam Guard or share passwords or recovery codes.")),
      ]
    }
  }

  /// `text` with each of `cues` in bold, wherever the translation placed it. A cue is found by
  /// the words that were put into the sentence, so a translation may move it freely.
  private static func emphasized(_ text: String, _ cues: [String]) -> AttributedString {
    var result = AttributedString(text)
    for cue in cues where !cue.isEmpty {
      if let range = result.range(of: cue) { result[range].inlinePresentationIntent = .stronglyEmphasized }
    }
    return result
  }
}
