import CommonCrypto
import CryptoKit
import Foundation

/// Steam's symmetric scheme for depot content and file names: AES-256, the first block
/// holding the IV (itself AES-ECB encrypted), the rest AES-CBC with PKCS#7 padding.
enum SteamDepotCrypto {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Steam content could not be decrypted (\(reason))" }
    }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else { throw Failure(reason: "key is \(key.count) bytes") }
        guard data.count >= 2 * kCCBlockSizeAES128, data.count % kCCBlockSizeAES128 == 0 else {
            throw Failure(reason: "\(data.count) bytes is not whole blocks")
        }
        let iv = try crypt(Data(data.prefix(kCCBlockSizeAES128)), key: key, iv: nil, options: CCOptions(kCCOptionECBMode))
        return try crypt(Data(data.dropFirst(kCCBlockSizeAES128)), key: key, iv: iv, options: CCOptions(kCCOptionPKCS7Padding))
    }

    /// The inverse of `decrypt`, with a caller-chosen IV; tests use it to build Steam-shaped content.
    static func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        let encryptedIV = try crypt(iv, key: key, iv: nil, options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCEncrypt))
        let body = try crypt(data, key: key, iv: iv, options: CCOptions(kCCOptionPKCS7Padding), operation: CCOperation(kCCEncrypt))
        return encryptedIV + body
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func crypt(_ input: Data, key: Data, iv: Data?, options: CCOptions,
                              operation: CCOperation = CCOperation(kCCDecrypt)) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    (iv ?? Data()).withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, key.count, iv == nil ? nil : ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure(reason: "CommonCrypto status \(status)") }
        return output.prefix(written)
    }
}
