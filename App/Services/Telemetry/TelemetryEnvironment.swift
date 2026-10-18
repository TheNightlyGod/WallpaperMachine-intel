import AppKit
import CryptoKit
import Metal
import Security

/// The machine facts a report carries, as numbers and checked words.
///
/// `DiagnosticEnvironment` writes the same facts as log lines for a bug report; this reads
/// them as fields and keeps only values that match a strict pattern, so an odd system
/// string can never carry anything else into a report. Names of displays, the host, the
/// language, the time zone and paths are left out.
enum TelemetryEnvironment {
    @MainActor
    static func app(bundle: Bundle = .main) -> TelemetryReport.AppInfo {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return TelemetryReport.AppInfo(
            version: matching(version, #"^\d{1,4}(\.\d{1,4}){0,3}$"#) ?? "0",
            build: matching(build, #"^[0-9A-Za-z.]{1,16}$"#) ?? "0",
            source: isSource(signingInformation: signingInformation()))
    }

    @MainActor
    static func mac(processInfo: ProcessInfo = .processInfo) -> TelemetryReport.MacInfo {
        let os = processInfo.operatingSystemVersion
        let main = NSScreen.main
        let displays = NSScreen.screens.prefix(8).map { screen in
            let scale = screen.backingScaleFactor
            return TelemetryReport.Display(
                width: Int((screen.frame.width * scale).rounded()),
                height: Int((screen.frame.height * scale).rounded()),
                scale: Double(scale), hz: screen.maximumFramesPerSecond, main: screen == main)
        }
        return TelemetryReport.MacInfo(
            model: DiagnosticEnvironment.sysctl("hw.model").flatMap { matching($0, #"^[A-Za-z]{2,16}\d{1,3},\d{1,3}$"#) },
            chip: DiagnosticEnvironment.sysctl("machdep.cpu.brand_string").flatMap(hardwareName),
            cores: processInfo.activeProcessorCount,
            memoryGB: Int((Double(processInfo.physicalMemory) / 1_073_741_824).rounded()),
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            gpu: MTLCreateSystemDefaultDevice().flatMap { hardwareName($0.name) },
            displays: Array(displays))
    }

    /// Each connected display's report entry, by display id.
    @MainActor
    static func displaysByID() -> [UInt32: TelemetryReport.Display] {
        let main = NSScreen.main
        var result: [UInt32: TelemetryReport.Display] = [:]
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { continue }
            let scale = screen.backingScaleFactor
            result[id] = TelemetryReport.Display(
                width: Int((screen.frame.width * scale).rounded()),
                height: Int((screen.frame.height * scale).rounded()),
                scale: Double(scale), hz: screen.maximumFramesPerSecond, main: screen == main)
        }
        return result
    }

    /// `Apple M3 Pro` passes; anything with other characters, or longer, is dropped.
    static func hardwareName(_ value: String) -> String? {
        matching(value.trimmingCharacters(in: .whitespaces), #"^[A-Za-z0-9 ()-]{1,48}$"#)
    }

    static func matching(_ value: String, _ pattern: String) -> String? {
        value.range(of: pattern, options: .regularExpression) == nil ? nil : value
    }

    /// SHA-1 of the project certificate `WallpaperMachine Code Signing` that releases are
    /// signed with, the hash the release's designated requirement names
    /// (`docs/build.md#release-signing`); replacing the certificate changes it.
    static let releaseCertificateSHA1 = "2bdf4e2431b7edeb731de288726c896480a0fa82"

    /// A copy is the release only when it is signed with the project certificate. That
    /// certificate is self-signed and carries no team, so a team says nothing here; a build
    /// from source is signed ad hoc, without certificates, or with its builder's own one.
    static func isSource(signingInformation: [String: Any]?) -> Bool {
        guard let signingInformation else { return true }
        if let flags = signingInformation[kSecCodeInfoFlags as String] as? NSNumber,
            SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc)
        {
            return true
        }
        guard let leaf = (signingInformation[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        else { return true }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02x", $0) }.joined() != releaseCertificateSHA1
    }

    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess
        else { return nil }
        return information as? [String: Any]
    }
}
