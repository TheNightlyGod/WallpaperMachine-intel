import XCTest
@testable import WallpaperMachine

/// A login keychain in memory, answering as macOS answers a build that did not save the item:
/// reading it is refused (`errSecAuthFailed`, once the person refuses the password prompt),
/// changing its data is allowed, and deleting it is refused (`errSecInvalidOwnerEdit`).
/// `refuseUpdates(with:)` makes every change fail, as when the person will not unlock the keychain.
final class MemoryKeychain: KeychainItemCalls, @unchecked Sendable {
    private struct Item {
        var data: Data
        var savedByAnotherBuild: Bool
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var refusedUpdate: OSStatus?

    func data(service: String, account: String) -> Data? {
        lock.withLock { items[Self.key(service, account)]?.data }
    }

    func holdItemSavedByAnotherBuild(service: String, account: String, data: Data) {
        lock.withLock { items[Self.key(service, account)] = Item(data: data, savedByAnotherBuild: true) }
    }

    func refuseUpdates(with status: OSStatus) {
        lock.withLock { refusedUpdate = status }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        lock.withLock {
            guard let item = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
            if item.savedByAnotherBuild { return (errSecAuthFailed, nil) }
            return (errSecSuccess, item.data as CFData)
        }
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(query)
            guard items[key] != nil else { return errSecItemNotFound }
            if let refusedUpdate { return refusedUpdate }
            if let data = attributes[kSecValueData as String] as? Data { items[key]?.data = data }
            return errSecSuccess
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = Item(data: data, savedByAnotherBuild: false)
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(query)
            guard let item = items[key] else { return errSecItemNotFound }
            if item.savedByAnotherBuild { return errSecInvalidOwnerEdit }
            items[key] = nil
            return errSecSuccess
        }
    }

    private static func key(_ query: [String: Any]) -> String {
        key(query[kSecAttrService as String] as? String ?? "", query[kSecAttrAccount as String] as? String ?? "")
    }

    private static func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }
}

final class KeychainGenericPasswordTests: XCTestCase {
    private let service = "test.wallpapermachine.keychain"
    private let account = "session"

    private func item(in keychain: MemoryKeychain) -> KeychainGenericPassword {
        KeychainGenericPassword(service: service, account: account, label: "Test sign-in", calls: keychain)
    }

    func testARefusedSaveReportsTheKeychainsReasonAndLeavesTheSavedItem() {
        let keychain = MemoryKeychain()
        let old = Data("old".utf8)
        keychain.holdItemSavedByAnotherBuild(service: service, account: account, data: old)
        keychain.refuseUpdates(with: errSecUserCanceled)

        XCTAssertThrowsError(try item(in: keychain).write(Data("new".utf8))) { error in
            XCTAssertEqual(error as? KeychainFailure, KeychainFailure(status: errSecUserCanceled))
        }
        XCTAssertEqual(keychain.data(service: service, account: account), old)
    }

    func testASaveWithoutAnItemAddsOneAndLaterSavesReplaceIt() throws {
        let password = item(in: MemoryKeychain())
        XCTAssertNil(try password.read())

        try password.write(Data("first".utf8))
        XCTAssertEqual(try password.read(), Data("first".utf8))
        try password.write(Data("second".utf8))
        XCTAssertEqual(try password.read(), Data("second".utf8))
    }

    func testAnItemTheKeychainRefusesIsAFailureNotAMissingItem() throws {
        let keychain = MemoryKeychain()
        keychain.holdItemSavedByAnotherBuild(service: service, account: account, data: Data("old".utf8))

        XCTAssertThrowsError(try item(in: keychain).read()) { error in
            XCTAssertEqual(error as? KeychainFailure, KeychainFailure(status: errSecAuthFailed))
        }
        XCTAssertNoThrow(try item(in: MemoryKeychain()).delete())
    }
}
