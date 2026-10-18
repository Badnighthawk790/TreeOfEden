import Foundation

/// A parsed node from Valve's KeyValues (VDF) text format used by Steam's
/// `libraryfolders.vdf` and `appmanifest_*.acf` files.
indirect enum VDFNode: Equatable {
    case string(String)
    case object([String: VDFNode])

    /// Looks up a child by key. Valve's KeyValues keys are case-insensitive
    /// (older Steam writes "LibraryFolders", newer writes "libraryfolders"),
    /// so an exact match is preferred and a case-insensitive one is the fallback.
    subscript(key: String) -> VDFNode? {
        guard case let .object(dict) = self else { return nil }
        if let exact = dict[key] { return exact }
        let lowered = key.lowercased()
        return dict.first(where: { $0.key.lowercased() == lowered })?.value
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: VDFNode]? {
        if case let .object(dict) = self { return dict }
        return nil
    }
}

/// A small recursive-descent parser for the subset of VDF that Steam uses.
/// Handles quoted/bare tokens, nested `{ }` objects, escapes, and `//` comments.
struct VDFParser {
    private let chars: [Character]
    private var index = 0

    private init(_ text: String) {
        self.chars = Array(text)
    }

    static func parse(_ text: String) -> VDFNode {
        var parser = VDFParser(text)
        return parser.parseObject()
    }

    private enum Token {
        case open           // structural {
        case close          // structural }
        case value(String)  // quoted or bare string
    }

    private mutating func parseObject() -> VDFNode {
        var dict: [String: VDFNode] = [:]
        loop: while let keyToken = readToken() {
            let key: String
            switch keyToken {
            case .close: break loop
            case .open: continue         // stray opening brace
            case .value(let k): key = k
            }
            guard let valueToken = readToken() else { break }
            switch valueToken {
            case .open: dict[key] = parseObject()
            case .close: dict[key] = .string(""); break loop
            case .value(let v): dict[key] = .string(v)
            }
        }
        return .object(dict)
    }

    /// Returns the next lexical token. Only *unquoted* braces are structural; a
    /// quoted "{"/"}" is a literal string value (Valve's format allows this).
    private mutating func readToken() -> Token? {
        skipWhitespaceAndComments()
        guard index < chars.count else { return nil }

        let c = chars[index]
        if c == "{" { index += 1; return .open }
        if c == "}" { index += 1; return .close }
        if c == "\"" { return .value(readQuotedString()) }

        var token = ""
        while index < chars.count {
            let ch = chars[index]
            if ch.isWhitespace || ch == "{" || ch == "}" || ch == "\"" { break }
            token.append(ch)
            index += 1
        }
        // Platform conditionals such as [$WIN32] or [!$X360] trail a value; they
        // are not keys, so skip them rather than shifting every pair after them.
        if token.hasPrefix("["), token.hasSuffix("]") {
            return readToken()
        }
        return .value(token)
    }

    private mutating func readQuotedString() -> String {
        index += 1 // opening quote
        var result = ""
        while index < chars.count, chars[index] != "\"" {
            if chars[index] == "\\", index + 1 < chars.count {
                index += 1
                switch chars[index] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(chars[index])
                }
            } else {
                result.append(chars[index])
            }
            index += 1
        }
        if index < chars.count { index += 1 } // closing quote
        return result
    }

    private mutating func skipWhitespaceAndComments() {
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace {
                index += 1
            } else if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else {
                break
            }
        }
    }
}
