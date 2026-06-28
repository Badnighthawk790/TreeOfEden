import Foundation

/// A parsed node from Valve's KeyValues (VDF) text format used by Steam's
/// `libraryfolders.vdf` and `appmanifest_*.acf` files.
indirect enum VDFNode: Equatable {
    case string(String)
    case object([String: VDFNode])

    subscript(key: String) -> VDFNode? {
        if case let .object(dict) = self { return dict[key] }
        return nil
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

    private mutating func parseObject() -> VDFNode {
        var dict: [String: VDFNode] = [:]
        while let key = readToken() {
            if key == "}" { break }
            if key == "{" { continue }
            guard let value = readToken() else { break }
            if value == "{" {
                dict[key] = parseObject()
            } else if value == "}" {
                dict[key] = .string("")
                break
            } else {
                dict[key] = .string(value)
            }
        }
        return .object(dict)
    }

    /// Returns the next lexical token. Braces are returned as their own tokens.
    private mutating func readToken() -> String? {
        skipWhitespaceAndComments()
        guard index < chars.count else { return nil }

        let c = chars[index]
        if c == "{" || c == "}" {
            index += 1
            return String(c)
        }
        if c == "\"" {
            return readQuotedString()
        }

        var token = ""
        while index < chars.count {
            let ch = chars[index]
            if ch.isWhitespace || ch == "{" || ch == "}" || ch == "\"" { break }
            token.append(ch)
            index += 1
        }
        return token
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
