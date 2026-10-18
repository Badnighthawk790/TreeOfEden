import Foundation
@testable import SteamXBridgeApp

/// A unique scratch directory removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sxb-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ relative: String, contents: String = "", executable: Bool = false) throws -> URL {
        try file(relative, data: Data(contents.utf8), executable: executable)
    }

    @discardableResult
    func file(_ relative: String, data: Data, executable: Bool = false) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        return target
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> URL {
        let link = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return link
    }
}

/// Canonical path for comparisons (realpath(3): resolves every symlink, including
/// Wine's relative dosdevices links and /var -> /private/var on macOS).
func canonical(_ url: URL?) -> String? {
    url.map(\.canonicalPath)
}

/// Builds Windows Shell Link (.lnk) files per [MS-SHLLINK] for parser tests.
enum ShellLinkBuilder {
    static func make(
        target: String,
        workingDirectory: String? = nil,
        arguments: String? = nil,
        unicodeLinkInfo: Bool = false,
        includeIDList: Bool = true
    ) -> Data {
        var flags: UInt32 = 0x2 | 0x80 // HasLinkInfo | IsUnicode
        if includeIDList { flags |= 0x1 }
        if workingDirectory != nil { flags |= 0x10 }
        if arguments != nil { flags |= 0x20 }

        var bytes: [UInt8] = []
        bytes += le32(0x4C)
        bytes += [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]
        bytes += le32(flags)
        bytes += [UInt8](repeating: 0, count: 0x4C - bytes.count)

        if includeIDList {
            bytes += le16(4)
            bytes += [0xAA, 0xBB, 0xCC, 0xDD]
        }

        bytes += linkInfo(target: target, unicode: unicodeLinkInfo)

        if let workingDirectory { bytes += countedUTF16(workingDirectory) }
        if let arguments { bytes += countedUTF16(arguments) }
        return Data(bytes)
    }

    private static func linkInfo(target: String, unicode: Bool) -> [UInt8] {
        let ansi = Array(target.unicodeScalars.map { $0.value < 128 ? UInt8($0.value) : UInt8(ascii: "?") }) + [0]
        let headerSize = unicode ? 0x24 : 0x1C
        let baseOffset = headerSize
        let suffixOffset = baseOffset + ansi.count
        var body: [UInt8] = ansi + [0] // ANSI base path, then an empty ANSI suffix
        var unicodeBaseOffset = 0
        var unicodeSuffixOffset = 0
        if unicode {
            unicodeBaseOffset = headerSize + body.count
            body += target.utf16.flatMap { le16(UInt32($0)) } + [0, 0]
            unicodeSuffixOffset = headerSize + body.count
            body += [0, 0]
        }
        var header: [UInt8] = []
        header += le32(UInt32(headerSize + body.count))
        header += le32(UInt32(headerSize))
        header += le32(1) // VolumeIDAndLocalBasePath
        header += le32(0) // VolumeIDOffset (not read by the parser)
        header += le32(UInt32(baseOffset))
        header += le32(0) // CommonNetworkRelativeLinkOffset
        header += le32(UInt32(suffixOffset))
        if unicode {
            header += le32(UInt32(unicodeBaseOffset))
            header += le32(UInt32(unicodeSuffixOffset))
        }
        return header + body
    }

    private static func countedUTF16(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        return le16(UInt32(units.count)) + units.flatMap { le16(UInt32($0)) }
    }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    static func le16(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
}
