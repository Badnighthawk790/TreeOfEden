import Foundation

/// An installed Steam game discovered from a local library.
struct SteamApp: Identifiable, Equatable {
    let appID: String
    let name: String
    let installDir: String
    let installPath: String

    var id: String { appID }
}

/// Discovers installed Steam games by reading `libraryfolders.vdf` and the
/// `appmanifest_*.acf` files Steam writes for every installed title.
struct SteamLibraryScanner {
    let steamRoot: URL
    private let fileManager: FileManager

    init(steamRoot: URL, fileManager: FileManager = .default) {
        self.steamRoot = steamRoot
        self.fileManager = fileManager
    }

    /// The default Steam location on macOS: `~/Library/Application Support/Steam`.
    static func defaultSteamRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
    }

    /// Library root folders, each of which contains a `steamapps` directory.
    /// Covers external drives listed in `libraryfolders.vdf`, in both the modern
    /// (object) and legacy (string) formats.
    func libraryRoots() -> [URL] {
        var roots: [URL] = []
        let vdfURL = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdfURL, encoding: .utf8) {
            let node = VDFParser.parse(text)
            if let folders = node["libraryfolders"]?.objectValue {
                for (key, value) in folders {
                    if let path = value["path"]?.stringValue {
                        roots.append(URL(fileURLWithPath: path))
                    } else if let path = value.stringValue, Int(key) != nil {
                        roots.append(URL(fileURLWithPath: path))
                    }
                }
            }
        }

        let standardizedRoot = steamRoot.standardizedFileURL
        if !roots.contains(where: { $0.standardizedFileURL == standardizedRoot }) {
            roots.append(steamRoot)
        }
        return roots
    }

    /// All installed games, de-duplicated by App ID and sorted by name.
    func installedApps() -> [SteamApp] {
        var apps: [SteamApp] = []
        for root in libraryRoots() {
            let steamapps = root.appendingPathComponent("steamapps")
            guard let entries = try? fileManager.contentsOfDirectory(
                at: steamapps,
                includingPropertiesForKeys: nil
            ) else { continue }

            for entry in entries where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
                if let app = parseManifest(at: entry, steamapps: steamapps) {
                    apps.append(app)
                }
            }
        }

        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.appID).inserted }
        return unique.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func parseManifest(at url: URL, steamapps: URL) -> SteamApp? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let node = VDFParser.parse(text)
        guard let state = node["AppState"]?.objectValue,
              let appID = state["appid"]?.stringValue,
              let name = state["name"]?.stringValue,
              let installDir = state["installdir"]?.stringValue else { return nil }

        let installPath = steamapps
            .appendingPathComponent("common")
            .appendingPathComponent(installDir)
            .path
        return SteamApp(appID: appID, name: name, installDir: installDir, installPath: installPath)
    }

    /// Common non-game executables to skip when guessing the main game binary.
    static let ignoredExecutableSubstrings = [
        "unitycrashhandler", "crashpad", "crashreporter", "uninstall",
        "vcredist", "vc_redist", "dxsetup", "directx", "redist", "dotnet",
        "installscript", "touchup", "easyanticheat", "battleye"
    ]

    /// Candidate game executables inside a title's install directory, largest
    /// first (the main binary is usually the biggest), filtering out installers
    /// and redistributables.
    func executableCandidates(for app: SteamApp) -> [String] {
        let dir = URL(fileURLWithPath: app.installPath)
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(path: String, size: Int)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "exe" {
            let lowerName = fileURL.lastPathComponent.lowercased()
            if Self.ignoredExecutableSubstrings.contains(where: { lowerName.contains($0) }) { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            candidates.append((fileURL.path, size))
        }
        return candidates.sorted { $0.size > $1.size }.map { $0.path }
    }
}
