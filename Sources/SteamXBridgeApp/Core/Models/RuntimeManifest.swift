import Foundation

/// Describes the Windows runtime bundled inside SteamXBridge.app: the upstream
/// archives it is made of (Wine, graphics layers), where each one is unpacked,
/// and where the engine's programs end up. Packaging writes it as
/// `Contents/Resources/Runtime/runtime.json`, next to the archives.
struct RuntimeManifest: Codable, Equatable {
    /// Names this build of the runtime; it is installed into a folder of that name.
    var id: String
    /// Shown in the UI ("Wine 11.0 with DXMT 0.70").
    var displayName: String
    var wineVersion: String
    var components: [Component]
    /// Files copied inside the runtime once everything is unpacked, for
    /// example a graphics layer's unix library into Wine's own lib folder.
    var copies: [Copy]
    /// Paths relative to the runtime folder.
    var loaderPath: String
    var wineserverPath: String
    /// Folders holding `x64/` (and optionally `x32/`) DLLs that are copied into
    /// prefixes for a graphics layer; nil when the runtime has none.
    var dxmtPath: String?
    var dxvkPath: String?
    /// What the runtime's engine supports.
    var features: [EngineFeature]
    /// Every executable is x86_64 and runs under Rosetta 2.
    var needsRosetta: Bool

    struct Component: Codable, Equatable {
        var name: String
        var version: String
        /// A plain file name in the bundle's Runtime folder.
        var archive: String
        /// Lower-case hex SHA-256 of the archive.
        var sha256: String
        var size: Int64
        /// Folder inside the runtime it is unpacked into.
        var destination: String
        /// Leading path components dropped while unpacking (tar --strip-components).
        var stripComponents: Int
        /// Only this folder of the archive is unpacked (Gcenx's Wine archives
        /// hold a whole "Wine Devel.app"; only its Resources/wine is needed).
        var member: String?
        var license: String
        /// Where packaging downloads the archive from (not used by the app).
        var url: String
        /// The corresponding source code, for the license notices.
        var sourceURL: String
    }

    struct Copy: Codable, Equatable {
        var from: String
        var to: String
    }

    static let fileName = "runtime.json"

    /// Rejects anything that could write outside the runtime folder or reads
    /// as a different archive than the one listed.
    func validate() throws {
        func fail(_ reason: String) -> RuntimeError { .invalidManifest(reason) }
        guard Self.isSafeName(id) else { throw fail("bad id \"\(id)\"") }
        guard !components.isEmpty else { throw fail("no components") }
        for component in components {
            guard Self.isSafeName(component.archive) else { throw fail("bad archive name \"\(component.archive)\"") }
            guard component.sha256.count == 64, component.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw fail("bad SHA-256 for \(component.archive)")
            }
            guard component.size > 0, (0...8).contains(component.stripComponents) else {
                throw fail("bad size or strip count for \(component.archive)")
            }
            guard Self.isSafeRelativePath(component.destination) else { throw fail("bad destination \"\(component.destination)\"") }
            if let member = component.member, !Self.isSafeMember(member) { throw fail("bad member \"\(member)\"") }
        }
        for copy in copies where !Self.isSafeRelativePath(copy.from) || !Self.isSafeRelativePath(copy.to) {
            throw fail("bad copy \(copy.from) -> \(copy.to)")
        }
        for path in [loaderPath, wineserverPath] + [dxmtPath, dxvkPath].compactMap({ $0 })
        where !Self.isSafeRelativePath(path) {
            throw fail("bad path \"\(path)\"")
        }
    }

    /// One path component of letters, digits, `.`, `-`, `_` and `+`, not starting with a dot.
    static func isSafeName(_ name: String) -> Bool {
        guard let first = name.first, first != "." else { return false }
        return name.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-+".contains($0)) }
    }

    /// A path inside an archive: relative, no `.` or `..` parts, no control
    /// characters, and not an option (spaces are fine: "Wine Devel.app").
    static func isSafeMember(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("-") && !parts.isEmpty && path.count <= 512
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// A relative path of safe names: no `..`, no absolute paths, no empty parts.
    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { isSafeName(String($0)) }
    }
}

enum RuntimeError: LocalizedError, Equatable {
    case notBundled
    case invalidManifest(String)
    case archiveMissing(String)
    case checksumMismatch(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case unpackFailed(String, status: Int32, output: String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "This copy of SteamXBridge does not include the Windows engine. Download the full app from the releases page, or build it with scripts/package_macos_app.sh."
        case .invalidManifest(let reason):
            return "The bundled Windows engine is damaged (\(reason)). Download SteamXBridge again."
        case .archiveMissing(let name):
            return "The bundled Windows engine is incomplete: \(name) is missing. Download SteamXBridge again."
        case .checksumMismatch(let name):
            return "\(name) inside SteamXBridge does not match its checksum, so it was not installed. Download SteamXBridge again."
        case .notEnoughSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "Setting up the Windows engine needs \(format.string(fromByteCount: needed)) of free space; \(format.string(fromByteCount: available)) is available."
        case .unpackFailed(let name, let status, let output):
            return "Unpacking \(name) failed (status \(status)).\(output.isEmpty ? "" : "\n\(output)")"
        case .incomplete(let path):
            return "The Windows engine was unpacked but \(path) is missing. Download SteamXBridge again."
        }
    }
}
