import Foundation

/// The parts of a Windows shortcut (.lnk) needed to launch its target.
struct ShellLink: Equatable {
    /// Full Windows path of the target, e.g. `C:\Program Files\Game\game.exe`.
    var targetPath: String?
    var arguments: String?
    var workingDirectory: String?
    var description: String?
    var relativePath: String?
}

/// Parses the Shell Link Binary File Format ([MS-SHLLINK]) that Windows and
/// Wine write for Start Menu and desktop shortcuts. Every read is bounds
/// checked; malformed files return nil instead of trapping.
enum ShellLinkParser {
    private static let headerSize: UInt32 = 0x4C
    private static let linkCLSID: [UInt8] = [
        0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]

    private struct Flags: OptionSet {
        let rawValue: UInt32
        static let hasLinkTargetIDList = Flags(rawValue: 1 << 0)
        static let hasLinkInfo = Flags(rawValue: 1 << 1)
        static let hasName = Flags(rawValue: 1 << 2)
        static let hasRelativePath = Flags(rawValue: 1 << 3)
        static let hasWorkingDir = Flags(rawValue: 1 << 4)
        static let hasArguments = Flags(rawValue: 1 << 5)
        static let hasIconLocation = Flags(rawValue: 1 << 6)
        static let isUnicode = Flags(rawValue: 1 << 7)
    }

    static func parse(contentsOf url: URL) -> ShellLink? {
        // Shortcuts are tiny; refuse anything implausibly large.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> ShellLink? {
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.uint32(at: 0) == headerSize,
              reader.slice(at: 4, count: 16) == linkCLSID,
              let rawFlags = reader.uint32(at: 20) else { return nil }
        let flags = Flags(rawValue: rawFlags)
        reader.offset = Int(headerSize)

        if flags.contains(.hasLinkTargetIDList) {
            guard let idListSize = reader.readUInt16() else { return nil }
            reader.offset += Int(idListSize)
        }

        var link = ShellLink()

        if flags.contains(.hasLinkInfo) {
            let start = reader.offset
            guard let infoSize = reader.uint32(at: start), infoSize >= 0x1C,
                  start + Int(infoSize) <= reader.bytes.count,
                  let infoHeaderSize = reader.uint32(at: start + 4),
                  let infoFlags = reader.uint32(at: start + 8),
                  let localBaseOffset = reader.uint32(at: start + 16),
                  let suffixOffset = reader.uint32(at: start + 24) else { return nil }
            let end = start + Int(infoSize)

            if infoFlags & 0x1 != 0 { // VolumeIDAndLocalBasePath
                var base: String?
                var suffix: String?
                if infoHeaderSize >= 0x24,
                   let unicodeBase = reader.uint32(at: start + 28),
                   let unicodeSuffix = reader.uint32(at: start + 32), unicodeBase != 0 {
                    base = reader.utf16CString(at: start + Int(unicodeBase), limit: end)
                    if unicodeSuffix != 0 {
                        suffix = reader.utf16CString(at: start + Int(unicodeSuffix), limit: end)
                    }
                }
                if base == nil, localBaseOffset != 0 {
                    base = reader.ansiCString(at: start + Int(localBaseOffset), limit: end)
                    if suffixOffset != 0 {
                        suffix = reader.ansiCString(at: start + Int(suffixOffset), limit: end)
                    }
                }
                if let base, !base.isEmpty {
                    link.targetPath = join(base, suffix ?? "")
                }
            }
            reader.offset = end
        }

        let unicode = flags.contains(.isUnicode)
        func next() -> String? { reader.readCountedString(unicode: unicode) }
        if flags.contains(.hasName) { link.description = next() }
        if flags.contains(.hasRelativePath) { link.relativePath = next() }
        if flags.contains(.hasWorkingDir) { link.workingDirectory = next() }
        if flags.contains(.hasArguments) { link.arguments = next() }

        if link.targetPath == nil, link.relativePath == nil { return nil }
        return link
    }

    private static func join(_ base: String, _ suffix: String) -> String {
        guard !suffix.isEmpty else { return base }
        if base.hasSuffix("\\") || suffix.hasPrefix("\\") { return base + suffix }
        return base + "\\" + suffix
    }
}

/// Little-endian, bounds-checked reads over a byte buffer.
private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    func uint32(at i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= bytes.count else { return nil }
        return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }

    func uint16(at i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= bytes.count else { return nil }
        return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }

    func slice(at i: Int, count: Int) -> [UInt8]? {
        guard i >= 0, count >= 0, i + count <= bytes.count else { return nil }
        return Array(bytes[i..<(i + count)])
    }

    mutating func readUInt16() -> UInt16? {
        guard let value = uint16(at: offset) else { return nil }
        offset += 2
        return value
    }

    func ansiCString(at i: Int, limit: Int) -> String? {
        guard i >= 0, i < min(limit, bytes.count) else { return nil }
        var j = i
        while j < min(limit, bytes.count), bytes[j] != 0 { j += 1 }
        // Windows "ANSI" is a code page; Latin-1 decoding never fails and keeps ASCII intact.
        return String(bytes: bytes[i..<j], encoding: .isoLatin1)
    }

    func utf16CString(at i: Int, limit: Int) -> String? {
        guard i >= 0 else { return nil }
        var units: [UInt16] = []
        var j = i
        while let unit = uint16(at: j), j + 2 <= limit, unit != 0 {
            units.append(unit)
            j += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// StringData entry: a 16-bit character count followed by the characters.
    mutating func readCountedString(unicode: Bool) -> String? {
        guard let count = readUInt16() else { return nil }
        let length = Int(count) * (unicode ? 2 : 1)
        guard let raw = slice(at: offset, count: length) else { return nil }
        offset += length
        if unicode {
            var units: [UInt16] = []
            units.reserveCapacity(Int(count))
            for k in stride(from: 0, to: raw.count, by: 2) {
                units.append(UInt16(raw[k]) | UInt16(raw[k + 1]) << 8)
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(bytes: raw, encoding: .isoLatin1)
    }
}
