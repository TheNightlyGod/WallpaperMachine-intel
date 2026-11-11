import AppKit
import CoreImage
import SwiftUI

/// Signing in to Steam by scanning a QR code with the Steam mobile app: no password and no
/// SteamCMD. Shown where a Steam sign-in is asked for; `onSignedIn` runs once Steam approved.
struct SteamQRSignInSection: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  let session: SteamNativeSession
  var onSignedIn: @MainActor () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch session.qr {
      case .idle:
        Button {
          start()
        } label: {
          Label("Sign in with a QR code", systemImage: "qrcode")
        }
        Text("Scan with the Steam mobile app and approve: no password or SteamCMD needed.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .starting:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Getting a code from Steam…").font(.system(size: 12))
        }
      case .waiting(let url, let scanned):
        HStack(alignment: .top, spacing: 14) {
          SteamQRCode(text: url)
            .frame(width: 148, height: 148)
          VStack(alignment: .leading, spacing: 8) {
            if scanned {
              Text("Scanned. Approve the sign-in on your phone.")
                .font(.system(size: 12, weight: .medium))
            } else {
              Text("Open the Steam app on your phone, tap the Steam Guard shield, then “Scan a QR code”.")
                .font(.system(size: 12))
            }
            Button("Cancel") { cancel() }
          }
        }
      case .failed(let failure):
        DownloadNotice(kind: .error, text: Self.message(for: failure))
        Button {
          start()
        } label: {
          Label("Show a new code", systemImage: "arrow.clockwise")
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onChange(of: session.isSignedIn) { _, signedIn in
      if signedIn { onSignedIn() }
    }
  }

  /// Worded when shown, so it follows the panel's language even after it changes.
  private static func message(for failure: SteamNativeSession.QRFailure) -> String {
    switch failure {
    case .expired: L("The QR code expired. Show a new one and scan it again.")
    case .unreachable: L("Could not reach Steam. Check your internet connection and try again.")
    case .failed: L("Steam sign-in failed. Try again.")
    }
  }

  private func start() {
    controller.launch(PanelActionCoordinator.key("startSteamQRSignIn")) { try await controller.startSteamQRSignIn() }
  }

  private func cancel() {
    controller.launch(PanelActionCoordinator.key("cancelSteamQRSignIn")) { try await controller.cancelSteamQRSignIn() }
  }
}

/// A QR code drawn crisp at any size from its modules, rebuilt only when the text changes.
private struct SteamQRCode: View {
  let text: String
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .padding(8)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
      } else {
        RoundedRectangle(cornerRadius: 6).fill(Color.white)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Steam sign-in QR code"))
    .task(id: text) { image = Self.render(text) }
  }

  static func render(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage,
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}
