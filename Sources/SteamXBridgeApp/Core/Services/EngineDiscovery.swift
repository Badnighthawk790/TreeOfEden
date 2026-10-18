import Foundation

/// Finds the Wine engines installed on this Mac. Nothing is executed: engines
/// are identified from their files, Info.plist and Mach-O headers.
struct EngineDiscovery {
    let home: URL
    let applicationDirectories: [URL]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationDirectories: [URL]? = nil) {
        self.home = home
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    func discover() -> [WineEngine] {
        var engines: [WineEngine] = []
        for directory in applicationDirectories {
            engines += crossOverEngines(in: directory)
            engines += wineHQEngines(in: directory)
            if let gptk = gptkApp(in: directory) { engines.append(gptk) }
        }
        if let gptk = gptkHomebrew() { engines.append(gptk) }
        engines += whiskyEngines()
        engines += sikarugirEngines()

        var seen = Set<String>()
        return engines.filter { seen.insert($0.id).inserted }
    }

    // MARK: CrossOver

    func crossOverEngines(in directory: URL) -> [WineEngine] {
        var result: [WineEngine] = []
        for (appName, kind) in [("CrossOver.app", EngineKind.crossOver), ("CrossOver Preview.app", .crossOverPreview)] {
            let app = directory.appendingPathComponent(appName, isDirectory: true)
            let bin = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin", isDirectory: true)
            let wrapper = bin.appendingPathComponent("wine")
            guard isFile(wrapper) else { continue }
            let info = Self.infoPlist(of: app)
            // Trust only the genuine bundle; impostor apps exist.
            if let identifier = info["CFBundleIdentifier"] as? String, !identifier.hasPrefix("com.codeweavers.") { continue }
            let version = info["CFBundleShortVersionString"] as? String
            let major = version.flatMap { Int($0.prefix(while: { $0.isNumber })) }

            var features: [EngineFeature] = [.dxvk, .wineD3D, .msync]
            if kind == .crossOver { features.append(.d3dMetal) } // the Preview has no D3DMetal
            if (major ?? 26) >= 25 { features.append(.dxmt) }
            if let major, major < 26 { features.append(.esync) } // CrossOver 26 removed ESync
            if (major ?? 26) >= 26 { features.append(.dlssMetalFX) } // DLSS via MetalFX arrived with 26

            let wineserver = bin.appendingPathComponent("wineserver")
            result.append(WineEngine(
                kind: kind,
                name: [kind.displayName, version].compactMap { $0 }.joined(separator: " "),
                version: version,
                loaderPath: wrapper.path,
                wineserverPath: isFile(wineserver) ? wineserver.path : nil,
                bundlePath: app.path,
                dxvkSourcePath: nil,
                architectures: architectures(of: wrapper),
                features: features
            ))
        }
        return result
    }

    /// CrossOver's bottle folder: the BottleDir preference when set, else the default.
    func crossOverBottleDirectory() -> URL {
        let prefs = home.appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.plist")
        if let data = try? Data(contentsOf: prefs),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let custom = root["BottleDir"] as? String, !custom.isEmpty {
            return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    // MARK: WineHQ / Gcenx builds

    func wineHQEngines(in directory: URL) -> [WineEngine] {
        var result: [WineEngine] = []
        for appName in ["Wine Stable.app", "Wine Devel.app", "Wine Staging.app", "Wine Crossover.app"] {
            let app = directory.appendingPathComponent(appName, isDirectory: true)
            let bin = app.appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)
            guard let loader = preferredLoader(in: bin) else { continue }
            let version = Self.infoPlist(of: app)["CFBundleShortVersionString"] as? String
            let title = String(appName.dropLast(4)) // "Wine Stable"
            result.append(WineEngine(
                kind: .wineHQ,
                name: [title, version].compactMap { $0 }.joined(separator: " "),
                version: version,
                loaderPath: loader.path,
                wineserverPath: wineserver(in: bin)?.path,
                bundlePath: app.path,
                dxvkSourcePath: nil,
                architectures: architectures(of: loader),
                features: hasD3DMetal(engineRoot: bin.deletingLastPathComponent()) ? [.d3dMetal] : []
            ))
        }
        return result
    }

    // MARK: Game Porting Toolkit

    /// Gcenx's prebuilt "Game Porting Toolkit.app".
    func gptkApp(in directory: URL) -> WineEngine? {
        let app = directory.appendingPathComponent("Game Porting Toolkit.app", isDirectory: true)
        let root = app.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        guard let loader = preferredLoader(in: bin) else { return nil }
        let version = Self.infoPlist(of: app)["CFBundleShortVersionString"] as? String
        return gptkEngine(loader: loader, bin: bin, root: root, version: version, bundle: app)
    }

    /// Apple's Homebrew formula, built into an Intel Homebrew under /usr/local.
    func gptkHomebrew() -> WineEngine? {
        let root = URL(fileURLWithPath: "/usr/local/opt/game-porting-toolkit", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        guard let loader = preferredLoader(in: bin) else { return nil }
        return gptkEngine(loader: loader, bin: bin, root: root, version: nil, bundle: nil)
    }

    private func gptkEngine(loader: URL, bin: URL, root: URL, version: String?, bundle: URL?) -> WineEngine {
        WineEngine(
            kind: .gamePortingToolkit,
            name: ["Game Porting Toolkit", version].compactMap { $0 }.joined(separator: " "),
            version: version,
            loaderPath: loader.path,
            wineserverPath: wineserver(in: bin)?.path,
            bundlePath: bundle?.path,
            dxvkSourcePath: nil,
            architectures: architectures(of: loader),
            features: (hasD3DMetal(engineRoot: root) ? [.d3dMetal] : []) + [.esync]
        )
    }

    // MARK: Whisky

    static let whiskyBundleIdentifiers = ["com.isaacmarovitz.Whisky", "com.franke.Whisky"]

    func whiskyEngines() -> [WineEngine] {
        Self.whiskyBundleIdentifiers.compactMap { identifier in
            let libraries = home.appendingPathComponent("Library/Application Support/\(identifier)/Libraries", isDirectory: true)
            let root = libraries.appendingPathComponent("Wine", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            guard let loader = preferredLoader(in: bin) else { return nil }
            let dxvk = libraries.appendingPathComponent("DXVK", isDirectory: true)
            let hasDXVK = FileManager.default.fileExists(atPath: dxvk.appendingPathComponent("x64").path)
            let version = whiskyWineVersion(libraries.appendingPathComponent("WhiskyWineVersion.plist"))
            let fork = identifier == "com.franke.Whisky"
            var features: [EngineFeature] = [.msync, .esync]
            if hasD3DMetal(engineRoot: root) { features.insert(.d3dMetal, at: 0) }
            if hasDXVK { features.append(.dxvk) }
            return WineEngine(
                kind: .whisky,
                name: (fork ? "WhiskyWine (community fork)" : "WhiskyWine") + (version.map { " \($0)" } ?? ""),
                version: version,
                loaderPath: loader.path,
                wineserverPath: wineserver(in: bin)?.path,
                bundlePath: nil,
                dxvkSourcePath: hasDXVK ? dxvk.path : nil,
                architectures: architectures(of: loader),
                features: features
            )
        }
    }

    func whiskyWineVersion(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        if let version = root["version"] as? [String: Any],
           let major = version["major"] as? Int, let minor = version["minor"] as? Int {
            let patch = version["patch"] as? Int ?? 0
            return "\(major).\(minor).\(patch)"
        }
        return root["version"] as? String
    }

    // MARK: Sikarugir

    /// Each Sikarugir wrapper app carries its own engine and prefix.
    func sikarugirEngines() -> [WineEngine] {
        sikarugirWrappers().compactMap { wrapper in
            let root = wrapper.appendingPathComponent("Contents/SharedSupport/wine", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            guard let loader = preferredLoader(in: bin) else { return nil }
            return WineEngine(
                kind: .sikarugir,
                name: "Sikarugir: \(wrapper.deletingPathExtension().lastPathComponent)",
                version: nil,
                loaderPath: loader.path,
                wineserverPath: wineserver(in: bin)?.path,
                bundlePath: wrapper.path,
                dxvkSourcePath: nil,
                architectures: architectures(of: loader),
                features: hasD3DMetal(engineRoot: root) ? [.d3dMetal, .esync] : []
            )
        }
    }

    func sikarugirWrappers() -> [URL] {
        let folder = home.appendingPathComponent("Applications/Sikarugir", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Custom engines

    /// Describes a wine binary the user picked. Returns nil when it is not a
    /// Wine loader or CrossOver wrapper.
    static func customEngine(at loader: URL) -> WineEngine? {
        let name = loader.lastPathComponent
        guard ["wine", "wine64"].contains(name), FileManager.default.isExecutableFile(atPath: loader.path) else { return nil }
        let bin = loader.deletingLastPathComponent()
        let discovery = EngineDiscovery()
        let isCrossOverWrapper = bin.path.hasSuffix("SharedSupport/CrossOver/bin")
        return WineEngine(
            kind: isCrossOverWrapper ? .crossOver : .custom,
            name: isCrossOverWrapper ? "CrossOver (custom location)" : "Custom: \(bin.deletingLastPathComponent().lastPathComponent)",
            version: nil,
            loaderPath: loader.path,
            wineserverPath: discovery.wineserver(in: bin)?.path,
            bundlePath: nil,
            dxvkSourcePath: nil,
            architectures: discovery.architectures(of: loader),
            features: isCrossOverWrapper
                ? [.d3dMetal, .dxmt, .dxvk, .wineD3D, .msync, .dlssMetalFX]
                : (discovery.hasD3DMetal(engineRoot: bin.deletingLastPathComponent()) ? [.d3dMetal, .esync] : [])
        )
    }

    // MARK: Helpers

    /// `wine` first (Wine 11 removed `wine64`), then `wine64` for older engines.
    func preferredLoader(in bin: URL) -> URL? {
        for name in ["wine", "wine64"] {
            let candidate = bin.appendingPathComponent(name)
            if isFile(candidate) { return candidate }
        }
        return nil
    }

    func wineserver(in bin: URL) -> URL? {
        let candidate = bin.appendingPathComponent("wineserver")
        return isFile(candidate) ? candidate : nil
    }

    /// D3DMetal ships as lib/external/D3DMetal.framework (plus libd3dshared.dylib).
    func hasD3DMetal(engineRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: engineRoot.appendingPathComponent("lib/external/D3DMetal.framework").path)
    }

    func architectures(of loader: URL) -> [CPUArchitecture] {
        if case .machO(let slices) = MachOInspector.inspect(loader) { return slices }
        return []
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func infoPlist(of app: URL) -> [String: Any] {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return root
    }
}

/// Rosetta 2 runs the x86_64 Wine loaders that almost every engine ships.
enum Rosetta {
    static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: runtimePath)
    }

    static let installCommand = "softwareupdate --install-rosetta --agree-to-license"
}
