import Foundation

/// Installs DXVK's DLLs into a plain-Wine prefix. Wine only loads them when
/// WINEDLLOVERRIDES marks them native (`LaunchPlanner.dxvkOverride`); copying
/// alone does nothing, and an override without the copy falls back to builtin.
///
/// The source folder holds `x64/` (64-bit DLLs, installed to system32) and
/// optionally `x32/` (32-bit DLLs, installed to syswow64), as DXVK-macOS
/// releases and Whisky's bundled copy do. CrossOver ships its own DXVK and
/// never needs this.
enum DXVKInstaller {
    /// The DLLs DXVK provides; anything else in the source is ignored.
    static let dllNames: Set<String> = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]

    static func isInstalled(in prefix: URL) -> Bool {
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        let marker = system32.appendingPathComponent(".steamxbridge-dxvk")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Copies DXVK into the prefix, replacing Wine's files of the same name.
    /// Returns the DLLs installed. The prefix must already be initialized.
    @discardableResult
    static func install(from source: URL, into prefix: URL) throws -> [String] {
        let fm = FileManager.default
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        var installed: [String] = []
        for (subfolder, destination) in [("x64", "system32"), ("x32", "syswow64")] {
            let from = source.appendingPathComponent(subfolder, isDirectory: true)
            let to = windows.appendingPathComponent(destination, isDirectory: true)
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
            // Skip non-DLL files rather than stopping at the first one.
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where dllNames.contains(file.lastPathComponent.lowercased()) {
                let target = to.appendingPathComponent(file.lastPathComponent.lowercased())
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
                installed.append("\(destination)/\(target.lastPathComponent)")
            }
        }
        guard !installed.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.appendingPathComponent("x64").path])
        }
        let marker = windows.appendingPathComponent("system32/.steamxbridge-dxvk")
        try Data(installed.joined(separator: "\n").utf8).write(to: marker)
        return installed
    }
}
