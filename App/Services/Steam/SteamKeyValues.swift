import Foundation

/// Valve's text KeyValues ("VDF"), the format of an app's product info: quoted keys,
/// quoted values or `{ … }` blocks, `//` comments.
indirect enum SteamKeyValues: Sendable, Equatable {
    case value(String)
    case block([(key: String, value: SteamKeyValues)])

    static func == (lhs: SteamKeyValues, rhs: SteamKeyValues) -> Bool {
        switch (lhs, rhs) {
        case (.value(let a), .value(let b)): a == b
        case (.block(let a), .block(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// The child at `key`, matched case-insensitively as Steam does.
    subscript(key: String) -> SteamKeyValues? {
        guard case .block(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var string: String? {
        if case .value(let value) = self { value } else { nil }
    }

    static func parse(_ text: String) throws -> SteamKeyValues {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return .block(try parser.entries(closedByBrace: false))
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func entries(closedByBrace: Bool) throws -> [(key: String, value: SteamKeyValues)] {
            var entries: [(key: String, value: SteamKeyValues)] = []
            while true {
                skipSpaceAndComments()
                guard index < scalars.count, scalars[index] != "\0" else {
                    if closedByBrace { throw SteamProto.DecodingError(reason: "KeyValues block left open") }
                    return entries
                }
                if scalars[index] == "}" {
                    guard closedByBrace else { throw SteamProto.DecodingError(reason: "KeyValues stray }") }
                    index += 1
                    return entries
                }
                let key = try token()
                skipSpaceAndComments()
                if index < scalars.count, scalars[index] == "{" {
                    index += 1
                    entries.append((key, .block(try self.entries(closedByBrace: true))))
                } else {
                    entries.append((key, .value(try token())))
                }
            }
        }

        mutating func token() throws -> String {
            guard index < scalars.count else { throw SteamProto.DecodingError(reason: "KeyValues ends early") }
            var text = String.UnicodeScalarView()
            if scalars[index] == "\"" {
                index += 1
                while index < scalars.count, scalars[index] != "\"" {
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        index += 1
                        switch scalars[index] {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default: text.append(scalars[index])
                        }
                    } else {
                        text.append(scalars[index])
                    }
                    index += 1
                }
                guard index < scalars.count else { throw SteamProto.DecodingError(reason: "KeyValues quote left open") }
                index += 1
            } else {
                while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
                      !"{}\"".unicodeScalars.contains(scalars[index]) {
                    text.append(scalars[index])
                    index += 1
                }
                guard !text.isEmpty else { throw SteamProto.DecodingError(reason: "KeyValues token expected") }
            }
            return String(text)
        }

        mutating func skipSpaceAndComments() {
            while index < scalars.count {
                if CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                    index += 1
                } else if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }
    }
}
