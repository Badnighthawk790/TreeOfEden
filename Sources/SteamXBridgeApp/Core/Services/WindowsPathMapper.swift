import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Maps Windows paths written by programs inside a Wine prefix (for example
/// `D:\SteamLibrary` in Steam's libraryfolders.vdf) to host paths, using the
/// prefix's `dosdevices` drive links.
struct WindowsPathMapper {
    let prefix: URL

    /// Returns the host URL for a Windows or POSIX path, or nil when the path
    /// cannot be mapped (unknown drive letter, UNC share, empty input).
    /// The result is not required to exist.
    func hostURL(forWindowsPath rawPath: String) -> URL? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        // Already a host path (macOS Steam, or a value we wrote ourselves).
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        // Strip Win32 long-path prefixes: \\?\C:\... and \??\C:\...
        for longPrefix in ["\\\\?\\", "\\??\\"] where path.hasPrefix(longPrefix) {
            path.removeFirst(longPrefix.count)
        }

        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":", isASCIILetter(scalars[0]) else {
            return nil // relative path, UNC share (\\server\share), or garbage
        }
        guard scalars.count == 2 || scalars[2] == "\\" || scalars[2] == "/" else {
            return nil // drive-relative "C:foo" is ambiguous; refuse it
        }

        let letter = String(scalars[0]).lowercased()
        guard let driveRoot = driveRoot(for: letter) else { return nil }

        let rest = String(String.UnicodeScalarView(scalars.dropFirst(2)))
        let components = rest
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        var url = driveRoot
        for component in components {
            url.appendPathComponent(component)
        }
        return url.standardizedFileURL
    }

    /// The host directory a drive letter points at. `dosdevices/<x>:` is
    /// usually a symlink (`c:` -> `../drive_c`, `z:` -> `/`). The link is read
    /// explicitly (relative targets resolve against `dosdevices`), because
    /// `resolvingSymlinksInPath()` does not resolve them on every platform.
    /// `c:` falls back to `drive_c` when there is no link.
    func driveRoot(for letter: String) -> URL? {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        let link = dosdevices.appendingPathComponent("\(letter.lowercased()):")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination, isDirectory: true)
                : dosdevices.appendingPathComponent(destination, isDirectory: true)
            return target.standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return link
        }
        if letter.lowercased() == "c" {
            return prefix.appendingPathComponent("drive_c", isDirectory: true)
        }
        return nil
    }

    private func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
    }
}

extension URL {
    /// The absolute path with every symlink resolved (realpath(3)) when the
    /// file exists, otherwise the standardized path. Use it to compare paths:
    /// it behaves the same on macOS (/var -> /private/var) and Linux.
    var canonicalPath: String {
        let path = standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when this file URL is `ancestor` or lies underneath it, comparing
    /// standardized paths component by component (so `/a/bc` is not inside `/a/b`).
    func isContained(in ancestor: URL) -> Bool {
        let child = standardizedFileURL.pathComponents
        let parent = ancestor.standardizedFileURL.pathComponents
        guard child.count >= parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }
}
