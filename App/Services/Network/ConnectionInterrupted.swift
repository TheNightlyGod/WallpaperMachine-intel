import Foundation

/// A connection that broke before the site answered, the way it does when something on the
/// network resets or drops the TLS handshake to that site: the handshake failed, the
/// certificate was not the site's, the connection was refused, reset or never answered, or the
/// name did not resolve. On a network that only reaches such a site through a proxy or VPN,
/// this almost always means the app's traffic to it went direct (the app follows the macOS
/// system proxy only), so the message says how to route it instead of showing the system's
/// "An SSL error has occurred" (`NSURLErrorSecureConnectionFailed`) and its siblings.
///
/// Being offline (`notConnectedToInternet`) and every other failure keep the system's own
/// description: the proxy hint would mislead there.
struct ConnectionInterrupted: LocalizedError, Equatable, Sendable {
    /// The host the connection was for, as the user would route it in a proxy client.
    let host: String

    var errorDescription: String? {
        String(
            localized: "The connection to \(host) was cut off or refused. This usually means WallpaperMachine’s traffic to it isn’t going through your proxy or VPN: turn on its system proxy or TUN mode, or route this domain through the proxy, then try again."
        )
    }

    /// The failures a blocked or reset connection shows up as.
    static let codes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
        .networkConnectionLost, .cannotConnectToHost, .timedOut,
        .dnsLookupFailed, .cannotFindHost,
    ]

    init(host: String) { self.host = host }

    /// `error` as an interrupted connection when it is one, naming the host that failed, or
    /// `site` when the error names none; nil for any other error, cancellation included.
    init?(_ error: Error, site: String) {
        guard let error = error as? URLError, Self.codes.contains(error.code) else { return nil }
        self.host = error.failingURL?.host.flatMap { $0.isEmpty ? nil : $0 } ?? site
    }

    /// `error`, replaced by an explained `ConnectionInterrupted` when it is one; anything else,
    /// cancellation included, is returned as it is.
    static func explaining(_ error: Error, site: String) -> Error {
        ConnectionInterrupted(error, site: site) ?? error
    }

    /// The text to show for `error`: the proxy explanation for an interrupted connection, the
    /// error's own description otherwise.
    static func message(for error: Error, site: String) -> String {
        explaining(error, site: site).localizedDescription
    }
}
