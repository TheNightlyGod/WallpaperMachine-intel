import Foundation

/// What a sign-in window took from the page: the session cookie, and the site's companion cookie
/// when it has one and the page set it.
struct WebSignInCookies: Equatable, Sendable {
    let session: String
    var companion: String?
}
