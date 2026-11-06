import Foundation

/// Which product a Wine engine comes from. This decides how programs are
/// launched and which settings apply.
enum EngineKind: String, Codable, CaseIterable {
    /// The runtime bundled with SteamXBridge (Wine plus graphics layers).
    case builtIn
    /// CodeWeavers CrossOver: bottles are addressed by name through its wrapper.
    case crossOver
    /// CrossOver Preview (native ARM64 test builds; no D3DMetal).
    case crossOverPreview
    /// Apple's Game Porting Toolkit (Gcenx's prebuilt app or Apple's Homebrew formula).
    case gamePortingToolkit
    /// Whisky's bundled WhiskyWine (the archived original or the community fork).
    case whisky
    /// WineHQ builds (Gcenx's Wine Stable / Devel / Staging apps, or Wine Crossover).
    case wineHQ
    /// The engine inside a Sikarugir wrapper app.
    case sikarugir
    /// A wine binary the user chose.
    case custom

    var displayName: String {
        switch self {
        case .builtIn: return "Built-in engine"
        case .crossOver: return "CrossOver"
        case .crossOverPreview: return "CrossOver Preview"
        case .gamePortingToolkit: return "Game Porting Toolkit"
        case .whisky: return "WhiskyWine"
        case .wineHQ: return "Wine"
        case .sikarugir: return "Sikarugir"
        case .custom: return "Custom engine"
        }
    }
}

/// An optional engine capability.
enum EngineFeature: String, Codable, CaseIterable {
    case d3dMetal, dxmt, dxvk, wineD3D, msync, esync, dlssMetalFX
}

/// A Wine engine installed on this Mac.
struct WineEngine: Identifiable, Equatable, Codable {
    /// Stable across launches: kind plus loader path.
    var id: String
    var kind: EngineKind
    /// "CrossOver 26.3.0", "Wine Stable 11.0", ...
    var name: String
    var version: String?
    /// The program to execute: CrossOver's `bin/wine` wrapper, or a `wine`/`wine64` loader.
    var loaderPath: String
    /// The engine's own wineserver (killing a prefix needs the matching one).
    var wineserverPath: String?
    /// The .app bundle the engine lives in, if any.
    var bundlePath: String?
    /// A DXVK folder with `x64`/`x32` subfolders that can be installed into prefixes.
    var dxvkSourcePath: String?
    /// The same for DXMT (the built-in engine).
    var dxmtSourcePath: String?
    /// Mach-O slices of the loader; empty when it is a script (CrossOver's wrapper).
    var architectures: [CPUArchitecture]
    var features: [EngineFeature]

    init(kind: EngineKind, name: String, version: String?, loaderPath: String, wineserverPath: String?,
         bundlePath: String?, dxvkSourcePath: String?, architectures: [CPUArchitecture], features: [EngineFeature],
         dxmtSourcePath: String? = nil) {
        self.id = "\(kind.rawValue):\(loaderPath)"
        self.kind = kind
        self.name = name
        self.version = version
        self.loaderPath = loaderPath
        self.wineserverPath = wineserverPath
        self.bundlePath = bundlePath
        self.dxvkSourcePath = dxvkSourcePath
        self.dxmtSourcePath = dxmtSourcePath
        self.architectures = architectures
        self.features = features
    }

    var loaderURL: URL { URL(fileURLWithPath: loaderPath) }

    /// CrossOver selects bottles by name with `--bottle` and must not be given WINEPREFIX.
    var isCrossOver: Bool { kind == .crossOver || kind == .crossOverPreview }

    /// The leading number of `version` ("26.3.0" -> 26).
    var majorVersion: Int? {
        guard let version else { return nil }
        return Int(version.prefix(while: { $0.isNumber }))
    }

    /// True when the loader is x86_64-only and so needs Rosetta 2 on Apple Silicon.
    var needsRosetta: Bool { architectures == [.x86_64] }

    func supports(_ feature: EngineFeature) -> Bool { features.contains(feature) }

    /// Graphics backends this engine can actually switch between. CrossOver
    /// selects one per bottle; plain engines use whatever Direct3D DLLs they
    /// ship (D3DMetal or WineD3D) unless a layer (DXMT, DXVK) is copied into
    /// the prefix over them.
    var graphicsBackends: [GraphicsBackend] {
        var backends: [GraphicsBackend] = [.automatic]
        if isCrossOver {
            if supports(.d3dMetal) { backends.append(.d3dMetal) }
            if supports(.dxmt) { backends.append(.dxmt) }
            if supports(.dxvk) { backends.append(.dxvk) }
            if supports(.wineD3D) { backends.append(.wineD3D) }
            return backends
        }
        // On the built-in engine Automatic already means DXMT.
        if dxmtSourcePath != nil, supports(.dxmt), automaticLayer != .dxmt { backends.append(.dxmt) }
        if dxvkSourcePath != nil, supports(.dxvk) { backends.append(.dxvk) }
        // Worth offering only where Automatic means something else.
        if automaticLayer != nil || (dxmtSourcePath != nil && supports(.dxmt)) { backends.append(.wineD3D) }
        return backends
    }

    /// The layer "Automatic" selects on a plain engine: DXMT on the built-in
    /// engine; elsewhere nil, leaving the engine's own Direct3D.
    var automaticLayer: GraphicsLayer? {
        kind == .builtIn && dxmtSourcePath != nil && supports(.dxmt) ? .dxmt : nil
    }

    /// The layer a plain-engine bottle runs with, and where its DLLs come
    /// from; nil means the engine's own Direct3D.
    func layer(for graphics: GraphicsBackend) -> (layer: GraphicsLayer, source: URL)? {
        guard !isCrossOver else { return nil }
        let chosen: GraphicsLayer?
        switch graphics {
        case .automatic: chosen = automaticLayer
        case .dxmt: chosen = supports(.dxmt) ? .dxmt : nil
        case .dxvk: chosen = supports(.dxvk) ? .dxvk : nil
        case .d3dMetal, .wineD3D: chosen = nil
        }
        switch chosen {
        case .dxmt: return dxmtSourcePath.map { (.dxmt, URL(fileURLWithPath: $0, isDirectory: true)) }
        case .dxvk: return dxvkSourcePath.map { (.dxvk, URL(fileURLWithPath: $0, isDirectory: true)) }
        case nil: return nil
        }
    }

    /// The folder holding the engine's `bin` and `lib/wine` (plain engines).
    var rootURL: URL { loaderURL.deletingLastPathComponent().deletingLastPathComponent() }

    /// What "Automatic" means on this engine, for the UI.
    var automaticGraphicsDescription: String {
        if isCrossOver { return "CrossOver picks a renderer per game" }
        if automaticLayer == .dxmt { return "DXMT for Direct3D 10/11, WineD3D for older games" }
        return supports(.d3dMetal) ? "D3DMetal" : "WineD3D"
    }
}
