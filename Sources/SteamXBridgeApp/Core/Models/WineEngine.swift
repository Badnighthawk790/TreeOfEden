import Foundation

/// Which product a Wine engine comes from. This decides how programs are
/// launched and which settings apply.
enum EngineKind: String, Codable, CaseIterable {
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
    /// Mach-O slices of the loader; empty when it is a script (CrossOver's wrapper).
    var architectures: [CPUArchitecture]
    var features: [EngineFeature]

    init(kind: EngineKind, name: String, version: String?, loaderPath: String, wineserverPath: String?,
         bundlePath: String?, dxvkSourcePath: String?, architectures: [CPUArchitecture], features: [EngineFeature]) {
        self.id = "\(kind.rawValue):\(loaderPath)"
        self.kind = kind
        self.name = name
        self.version = version
        self.loaderPath = loaderPath
        self.wineserverPath = wineserverPath
        self.bundlePath = bundlePath
        self.dxvkSourcePath = dxvkSourcePath
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
    /// ship (D3DMetal or WineD3D) unless DXVK is installed over them.
    var graphicsBackends: [GraphicsBackend] {
        var backends: [GraphicsBackend] = [.automatic]
        if isCrossOver {
            if supports(.d3dMetal) { backends.append(.d3dMetal) }
            if supports(.dxmt) { backends.append(.dxmt) }
            if supports(.dxvk) { backends.append(.dxvk) }
            if supports(.wineD3D) { backends.append(.wineD3D) }
        } else if supports(.dxvk) {
            backends.append(.dxvk)
        }
        return backends
    }

    /// What "Automatic" means on this engine, for the UI.
    var automaticGraphicsDescription: String {
        if isCrossOver { return "CrossOver picks a renderer per game" }
        return supports(.d3dMetal) ? "D3DMetal" : "WineD3D"
    }
}
