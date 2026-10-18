import Foundation

/// Reads and edits CrossOver's `cxbottle.conf` while preserving everything it
/// does not touch (comments, ordering, unknown keys).
///
/// The format is INI-like:
///
///     ;; comment
///     [Bottle]
///     "Template" = "win10_64"
///     [EnvironmentVariables]
///     "CX_GRAPHICS_BACKEND" = "d3dmetal"
///
/// Keys and values are usually double-quoted; spaces around `=` are optional,
/// and a key may appear more than once (the last occurrence wins).
struct CrossOverBottleConfig: Equatable {
    private(set) var lines: [String]

    init(text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    /// The value of `key` in `section`; the last occurrence wins.
    func value(section: String, key: String) -> String? {
        var current: String?
        var result: String?
        for line in lines {
            if let name = Self.sectionName(line) {
                current = name
            } else if current?.caseInsensitiveCompare(section) == .orderedSame,
                      let pair = Self.keyValue(line), pair.key == key {
                result = pair.value
            }
        }
        return result
    }

    /// Sets `key` in `section` (creating the section if needed), or removes
    /// every occurrence of it when `value` is nil.
    mutating func setValue(_ value: String?, section: String, key: String) {
        var current: String?
        var sectionStart: Int?
        var sectionEnd: Int?
        var occurrences: [Int] = []

        for (index, line) in lines.enumerated() {
            if let name = Self.sectionName(line) {
                if current?.caseInsensitiveCompare(section) == .orderedSame { sectionEnd = index }
                current = name
                if name.caseInsensitiveCompare(section) == .orderedSame, sectionStart == nil {
                    sectionStart = index
                    sectionEnd = nil
                }
            } else if current?.caseInsensitiveCompare(section) == .orderedSame,
                      let pair = Self.keyValue(line), pair.key == key {
                occurrences.append(index)
            }
        }
        if sectionStart != nil, sectionEnd == nil, current?.caseInsensitiveCompare(section) == .orderedSame {
            sectionEnd = lines.count
        }

        guard let value else {
            for index in occurrences.reversed() { lines.remove(at: index) }
            return
        }
        let newLine = "\"\(key)\" = \"\(Self.escape(value))\""
        if let first = occurrences.first {
            lines[first] = newLine
            for index in occurrences.dropFirst().reversed() { lines.remove(at: index) }
        } else if let end = sectionEnd {
            // Append after the section's last non-blank line.
            var insertAt = end
            while let start = sectionStart, insertAt > start + 1,
                  lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(newLine, at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append(newLine)
        }
    }

    static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }

        var key: String
        var rest: Substring
        if trimmed.hasPrefix("\"") {
            let afterQuote = trimmed.dropFirst()
            guard let close = afterQuote.firstIndex(of: "\"") else { return nil }
            key = String(afterQuote[..<close])
            rest = afterQuote[afterQuote.index(after: close)...]
        } else {
            guard let equals = trimmed.firstIndex(of: "=") else { return nil }
            key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            rest = trimmed[equals...]
        }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return nil }
        let rawValue = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if rawValue.count >= 2, rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
            return (key, unescape(String(rawValue.dropFirst().dropLast())))
        }
        return (key, rawValue)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

extension BottleSettings {
    /// The settings an existing CrossOver bottle already has, read from its
    /// cxbottle.conf `[EnvironmentVariables]`, so linking a bottle shows (and
    /// later preserves) what the user chose in CrossOver. Fields CrossOver does
    /// not store keep their defaults.
    init(crossOverConfig config: CrossOverBottleConfig) {
        self.init()
        func value(_ key: String) -> String? {
            config.value(section: "EnvironmentVariables", key: key)?.trimmingCharacters(in: .whitespaces)
        }
        switch value("CX_GRAPHICS_BACKEND")?.lowercased() {
        case "d3dmetal": graphics = .d3dMetal
        case "dxmt": graphics = .dxmt
        case "dxvk": graphics = .dxvk
        case "wined3d": graphics = .wineD3D
        default: graphics = .automatic // missing, empty or unknown means Auto
        }
        msync = value("WINEMSYNC") == "1"
        esync = value("WINEESYNC") == "1"
        metalHUD = value("MTL_HUD_ENABLED") == "1"
        dlssMetalFX = value("D3DM_ENABLE_METALFX") == "1" || value("DXMT_ENABLE_NVEXT") == "1"
        switch value("D3DM_SUPPORT_DXR") {
        case "1": rayTracing = .on
        case "0": rayTracing = .off
        default: rayTracing = .automatic
        }
        advertiseAVX = value("ROSETTA_ADVERTISE_AVX") != "0"
    }
}
