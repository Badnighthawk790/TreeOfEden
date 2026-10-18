import Foundation

/// A Wine prefix created by another app that SteamXBridge can link to.
struct ExternalBottle: Equatable, Identifiable {
    let name: String
    let prefix: URL
    /// "CrossOver", "Whisky" or "Wine prefix".
    let source: String
    /// True when the Windows Steam client is installed inside it.
    let hasSteam: Bool
    /// Which engine created it, when known: a Whisky bundle identifier, a
    /// Sikarugir wrapper path, or "gptk" for the Game Porting Toolkit prefix.
    var engineHint: String? = nil

    var id: String { prefix.standardizedFileURL.path }
}

/// Finds existing bottles from CrossOver, Whisky and plain Wine / Game Porting
/// Toolkit prefixes, so games already installed there can be used without
/// reinstalling them.
struct ExternalBottleFinder {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    static let crossOverSource = "CrossOver"

    func discover() -> [ExternalBottle] {
        var found: [ExternalBottle] = []
        var seen = Set<String>()
        func add(_ name: String, _ prefix: URL, _ source: String, hint: String? = nil) {
            let key = prefix.canonicalPath
            guard BottleStore.looksLikePrefix(prefix), seen.insert(key).inserted else { return }
            found.append(ExternalBottle(
                name: name,
                prefix: prefix.standardizedFileURL,
                source: source,
                hasSteam: SteamInstallation.locate(inPrefix: prefix) != nil,
                engineHint: hint
            ))
        }

        // CrossOver: every folder holding a cxbottle.conf in its bottle directory
        // is a bottle, and the folder name is the bottle name CrossOver's
        // `--bottle` option expects.
        let crossOver = EngineDiscovery(home: home).crossOverBottleDirectory()
        for folder in subdirectories(of: crossOver)
        where FileManager.default.fileExists(atPath: folder.appendingPathComponent("cxbottle.conf").path)
            || BottleStore.looksLikePrefix(folder) {
            add(folder.lastPathComponent, folder, Self.crossOverSource)
        }

        // Whisky (the archived original and the community fork): bottles in its
        // default folder plus custom locations tracked in BottleVM.plist; the
        // name lives in each bottle's Metadata.plist (info.name).
        for identifier in EngineDiscovery.whiskyBundleIdentifiers {
            let container = home.appendingPathComponent("Library/Containers/\(identifier)", isDirectory: true)
            var whiskyFolders = subdirectories(of: container.appendingPathComponent("Bottles", isDirectory: true))
            whiskyFolders += whiskyTrackedPaths(plist: container.appendingPathComponent("BottleVM.plist"))
            for folder in whiskyFolders {
                add(whiskyBottleName(at: folder) ?? folder.lastPathComponent, folder, "Whisky", hint: identifier)
            }
        }

        // Sikarugir wrappers keep their prefix inside the wrapper app.
        for wrapper in EngineDiscovery(home: home).sikarugirWrappers() {
            add(wrapper.deletingPathExtension().lastPathComponent,
                wrapper.appendingPathComponent("Contents/SharedSupport/prefix", isDirectory: true), "Sikarugir",
                hint: wrapper.path)
        }

        // Plain Wine and the Game Porting Toolkit README's suggested prefix.
        for relative in [".wine", "my-game-prefix"] {
            let prefix = home.appendingPathComponent(relative, isDirectory: true)
            add(relative == ".wine" ? "Default Wine prefix" : "my-game-prefix", prefix, "Wine prefix",
                hint: relative == "my-game-prefix" ? "gptk" : nil)
        }

        return found
    }

    private func subdirectories(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Bottle paths from Whisky's BottleVM.plist (a Codable `paths: [URL]` array,
    /// where each URL is stored as a dictionary with a "relative" file URL string).
    func whiskyTrackedPaths(plist: URL) -> [URL] {
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let paths = root["paths"] as? [Any] else { return [] }
        return paths.compactMap { entry -> URL? in
            let string = (entry as? [String: Any])?["relative"] as? String ?? entry as? String
            guard let string else { return nil }
            if let url = URL(string: string), url.isFileURL { return url }
            return string.hasPrefix("/") ? URL(fileURLWithPath: string) : nil
        }
    }

    func whiskyBottleName(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Metadata.plist")),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let info = root["info"] as? [String: Any],
              let name = info["name"] as? String, !name.isEmpty else { return nil }
        return name
    }
}
