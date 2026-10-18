import Security
import XCTest

@testable import WallpaperMachine

/// A report calls a copy the release only when the project certificate signed it.
final class TelemetryEnvironmentTests: XCTestCase {
    /// The project certificate, as every release carries it in its signature.
    private static let projectCertificate = """
        MIIEjDCCAvSgAwIBAgIULUlf5plX+1eoScbA30YTMFz4ZMAwDQYJKoZIhvcNAQELBQAwQzEmMCQGA1UEAwwdV2FsbHBhcGVyTWFj
        aGluZSBDb2RlIFNpZ25pbmcxGTAXBgNVBAoMEFdhbGxwYXBlck1hY2hpbmUwHhcNMjYwOTI3MDg1MzQyWhcNNDYwOTIyMDg1MzQy
        WjBDMSYwJAYDVQQDDB1XYWxscGFwZXJNYWNoaW5lIENvZGUgU2lnbmluZzEZMBcGA1UECgwQV2FsbHBhcGVyTWFjaGluZTCCAaIw
        DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAJDQqjjWSxccbMx5cdv11dsHSclGFqyHG0c/bU9d8bt1LPx8ploOpT3DfhY2u9HO
        9StM7uN2abWmcDNhjrrEe4N4lkYTHxZq6v3xW/df/R2wq5xy7Nk2TMq4Q3tiGUZw9yatastzTWQRBOvXRqCEhV6LUyXuF/G9M7fx
        +pHz2eh2mVSSTwhKYJONxRTmC/nvwdmMjGKpKIYuA+4RUd8bPP+e5sy1RWEdHgId+a7upG6yLc62k9+UHNz+3ioWyqI+q+G4NRpO
        WCFdnGYyIzvnenXDqbWFRxdI4We7p2wwqBpx6FFK+ABpYTU2UmHqOnXGVIXGMZAZUTvo5ufpWJ0PJXSUWq28xCb5NiQf6WYcr915
        uj3TaFRVk60ZqlIE9KirS9IaGypBnb68/x4RtyTEuppxqB7YfnB2RFjMVfolnv7lmhTf/XsP5O+h+Yv+8GprOiGH2TZjQGG2fVph
        e1sX+Bip7JULXYgaAMMPTapVNLiSnCF20i2FmN1q3cUOEGq3EwIDAQABo3gwdjAdBgNVHQ4EFgQUIAXe4UoG8T8yPKoV/arygI2f
        cUAwHwYDVR0jBBgwFoAUIAXe4UoG8T8yPKoV/arygI2fcUAwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/
        BAwwCgYIKwYBBQUHAwMwDQYJKoZIhvcNAQELBQADggGBAHhQYGS9s4mzvQ+GYp4E44YM5QeiCazJo/asoTe8SW9TXaTYfy33tgTY
        G3mF6v5xf0LzpcgTu84k/n+aW9JeW+QpkXPG2a9l9z9NlhpY2UG9tW6Xbyg6uPiv6sekWcpm2PI7U4OnZC52lZURTrSMTEJ5l1Jd
        9qkG83MDw4ZOlkPjeWq/KRDIRvmtnH7EFnp05fdYJawyaChvPeRUUUqEaaxxpfaCTLOBuMcoQ3ZBWms19qOdL+x2bjmEpA132WF5
        +tsDGR1JkdBjlKIFZwqQ8Wo7FzOIUsAf0Qm68J87hKa/a3QcEt9y1w98EPhsrLqdjXDjYVHFEMCtXewYLc6AM3/LBJvxOSG0pWB7
        SUD3m+OdY++2xustDIZ/s99EuaryllHYQddeWd/gotGq0x6Gdv7i9qxp4ULO5tLAQnGuSpjRwqM11oEgwda8zk3P9As7TNk0/Mhf
        sHgeYUcwezZYsWus3+BQPwvqWKKwV7TZsWoFxo+ekAUIfe7VRuqC/CDHXg==
        """

    /// A throwaway self-signed certificate with the project certificate's name and another key.
    private static let sameNameCertificate = """
        MIICAjCCAamgAwIBAgIUNygxVauetWbvfZIBM9VyADxFBb0wCgYIKoZIzj0EAwIwQzEmMCQGA1UEAwwdV2FsbHBhcGVyTWFjaGlu
        ZSBDb2RlIFNpZ25pbmcxGTAXBgNVBAoMEFdhbGxwYXBlck1hY2hpbmUwHhcNMjYxMDE4MTMxMjU0WhcNNDYxMDEzMTMxMjU0WjBD
        MSYwJAYDVQQDDB1XYWxscGFwZXJNYWNoaW5lIENvZGUgU2lnbmluZzEZMBcGA1UECgwQV2FsbHBhcGVyTWFjaGluZTBZMBMGByqG
        SM49AgEGCCqGSM49AwEHA0IABO5nJO9mZYNCy1L8IJjUYlA78evCcBPWo/PocokoUAsdBJU2xfR8vpso0pzHHt/qnVNUndmPUu5A
        /H4MMsGjMjWjezB5MB0GA1UdDgQWBBRnhVWZJHO21Q/4MhITqOanQusBoDAfBgNVHSMEGDAWgBRnhVWZJHO21Q/4MhITqOanQusB
        oDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDAzAKBggqhkjOPQQDAgNHADBE
        AiBjRMRkOwJP5cOlGHpYZoj5u08w+hXycRbcM4AeRmqutQIgW21ehRVTy4JYoUnzyLIJJSJZTMJfc5LbxY643v8+EYU=
        """

    private func certificate(_ base64: String) throws -> SecCertificate {
        let der = try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    /// The fields `SecCodeCopySigningInformation` reports for a signature with these flags and certificates.
    private func signature(flags: SecCodeSignatureFlags, certificates: [SecCertificate]?) -> [String: Any] {
        var information: [String: Any] = [
            kSecCodeInfoIdentifier as String: "app.wallpapermachine",
            kSecCodeInfoFlags as String: NSNumber(value: flags.rawValue),
        ]
        information[kSecCodeInfoCertificates as String] = certificates
        return information
    }

    func testAdHocSignatureIsSource() {
        XCTAssertTrue(TelemetryEnvironment.isSource(signingInformation: signature(flags: .adhoc, certificates: nil)))
    }

    func testProjectCertificateIsRelease() throws {
        let information = signature(flags: [], certificates: [try certificate(Self.projectCertificate)])
        XCTAssertFalse(TelemetryEnvironment.isSource(signingInformation: information))
    }

    func testAnotherCertificateWithTheSameNameIsSource() throws {
        let information = signature(flags: [], certificates: [try certificate(Self.sameNameCertificate)])
        XCTAssertTrue(TelemetryEnvironment.isSource(signingInformation: information))
    }

    func testProjectCertificateBelowAnotherLeafIsSource() throws {
        let information = signature(
            flags: [],
            certificates: [try certificate(Self.sameNameCertificate), try certificate(Self.projectCertificate)])
        XCTAssertTrue(TelemetryEnvironment.isSource(signingInformation: information))
    }

    func testUnreadableSignatureIsSource() {
        XCTAssertTrue(TelemetryEnvironment.isSource(signingInformation: nil))
        XCTAssertTrue(TelemetryEnvironment.isSource(signingInformation: [:]))
    }
}
