import Foundation

/// A game installed by the Windows Steam client inside a bottle.
struct SteamApp: Identifiable, Equatable, Hashable {
    let appID: String
    let name: String
    /// Host path of the game folder: <library>/steamapps/common/<installdir>.
    let installDirectory: URL
    /// The library root holding the game (the folder that contains `steamapps`).
    let libraryRoot: URL
    /// Steam's StateFlags; bit 4 (value 4) means fully installed.
    let stateFlags: Int
    let sizeOnDisk: Int64?

    var id: String { appID }
    var isFullyInstalled: Bool { stateFlags & 4 != 0 }
}

/// The Windows Steam client installed inside a prefix.
struct SteamInstallation: Equatable {
    let prefix: URL
    /// The Steam folder, e.g. <prefix>/drive_c/Program Files (x86)/Steam.
    let root: URL

    var steamExecutable: URL { root.appendingPathComponent("steam.exe") }

    /// Finds steam.exe in a prefix's usual install locations.
    static func locate(inPrefix prefix: URL) -> SteamInstallation? {
        let candidates = [
            "drive_c/Program Files (x86)/Steam",
            "drive_c/Program Files/Steam",
        ]
        for relative in candidates {
            let root = prefix.appendingPathComponent(relative, isDirectory: true)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("steam.exe").path) {
                return SteamInstallation(prefix: prefix, root: root)
            }
        }
        return nil
    }
}

/// Reads the libraries and installed games of a Windows Steam client in a bottle.
struct SteamLibraryReader {
    let installation: SteamInstallation

    private var mapper: WindowsPathMapper { WindowsPathMapper(prefix: installation.prefix) }

    /// Every library root: Steam's own folder plus each path in libraryfolders.vdf.
    /// Windows paths (C:\..., D:\SteamLibrary) are mapped through the prefix's drives;
    /// roots that do not exist are skipped.
    func libraryRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.path),
                  seen.insert(url.canonicalPath).inserted else { return }
            roots.append(url.standardizedFileURL)
        }

        add(installation.root)
        // Steam writes libraryfolders.vdf under steamapps/; newer clients also keep one in config/.
        for relative in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            let file = installation.root.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for path in Self.libraryPaths(fromLibraryFolders: text) {
                if let url = mapper.hostURL(forWindowsPath: path) { add(url) }
            }
        }
        return roots
    }

    /// Library paths listed in a libraryfolders.vdf, in both the modern format
    /// ("0" { "path" "C:\\..." }) and the legacy one ("1" "D:\\SteamLibrary").
    static func libraryPaths(fromLibraryFolders text: String) -> [String] {
        guard let folders = VDFParser.parse(text)["libraryfolders"]?.objectValue else { return [] }
        var paths: [String] = []
        for key in folders.keys.sorted(by: { (Int($0) ?? .max) < (Int($1) ?? .max) }) {
            guard let value = folders[key] else { continue }
            if let path = value["path"]?.stringValue {
                paths.append(path)
            } else if Int(key) != nil, let path = value.stringValue {
                paths.append(path)
            }
        }
        return paths
    }

    /// Installed games across every library, de-duplicated by App ID and sorted by name.
    func installedApps() -> [SteamApp] {
        var apps: [SteamApp] = []
        var seen = Set<String>()
        for root in libraryRoots() {
            let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
                guard let text = try? String(contentsOf: entry, encoding: .utf8),
                      let app = Self.parseManifest(text, libraryRoot: root),
                      seen.insert(app.appID).inserted else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Parses one appmanifest_*.acf. Returns nil for malformed manifests and for
    /// an `installdir` that would escape steamapps/common ("..", "/", empty).
    static func parseManifest(_ text: String, libraryRoot: URL) -> SteamApp? {
        guard let state = VDFParser.parse(text)["AppState"],
              let appID = state["appid"]?.stringValue, !appID.isEmpty, appID.allSatisfy(\.isNumber),
              let installDir = state["installdir"]?.stringValue else { return nil }
        let name = state["name"]?.stringValue ?? "App \(appID)"

        let common = libraryRoot.appendingPathComponent("steamapps/common", isDirectory: true)
        let components = installDir.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        var folder = common
        for component in components { folder.appendPathComponent(String(component)) }
        guard folder.isContained(in: common), folder.standardizedFileURL.path != common.standardizedFileURL.path else {
            return nil
        }

        return SteamApp(
            appID: appID,
            name: name,
            installDirectory: folder.standardizedFileURL,
            libraryRoot: libraryRoot,
            stateFlags: Int(state["StateFlags"]?.stringValue ?? "") ?? 0,
            sizeOnDisk: Int64(state["SizeOnDisk"]?.stringValue ?? "")
        )
    }
}

/// Guesses a game's main executable, for launching without the Steam client.
enum ExecutableFinder {
    /// Folder names that hold installers, runtimes and helpers rather than games.
    static let ignoredDirectories: Set<String> = [
        "_commonredist", "commonredist", "redist", "redistributables", "directx", "dotnet",
        "vcredist", "__installer", "installer", "installers", "support", "easyanticheat",
        "battleye", "crashreporter", "crashpad", "launcher-redist", "prereqs", "prerequisites",
    ]
    /// File-name fragments of executables that are never the game itself.
    static let ignoredNameFragments = [
        "unitycrashhandler", "crashpad", "crashreporter", "crashhandler", "uninst", "unins0",
        "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "dotnet", "ndp4", "setup", "installer",
        "easyanticheat", "battleye", "redist", "updater", "touchup", "cefprocess", "quicksfv",
    ]

    /// Candidate executables under `folder`, best first. The search is bounded
    /// in depth and file count so huge game folders cannot stall the app.
    static func candidates(in folder: URL, preferredName: String? = nil, maxDepth: Int = 4, maxFiles: Int = 20_000) -> [URL] {
        let found = DirectoryWalker.files(under: folder, maxDepth: maxDepth, maxEntries: maxFiles) {
            !ignoredDirectories.contains($0.lastPathComponent.lowercased())
        }.filter { entry in
            let lower = entry.url.lastPathComponent.lowercased()
            return entry.url.pathExtension.lowercased() == "exe"
                && !ignoredNameFragments.contains(where: { lower.contains($0) })
        }

        let preferred = preferredName.map { normalize($0) }
        func score(_ entry: DirectoryWalker.Entry) -> (Int, Int, Int) {
            let stem = normalize(entry.url.deletingPathExtension().lastPathComponent)
            let nameMatch = preferred.map { !$0.isEmpty && !stem.isEmpty && (stem == $0 || $0.contains(stem) || stem.contains($0)) } ?? false
            // Prefer a name match, then shallower files, then larger ones.
            return (nameMatch ? 0 : 1, entry.depth, -entry.size)
        }
        return found.sorted { score($0) < score($1) }.map(\.url)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
