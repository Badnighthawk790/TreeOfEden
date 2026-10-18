import Foundation

/// Direct3D implementation used inside a bottle.
enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    /// Let the engine decide (its own default, usually D3DMetal or DXMT).
    case automatic
    /// Apple's D3DMetal (Game Porting Toolkit): Direct3D 11/12 straight to Metal.
    case d3dMetal
    /// DXMT: Direct3D 10/11 to Metal, open source.
    case dxmt
    /// DXVK: Direct3D 9/10/11 to Vulkan, then Metal through MoltenVK.
    case dxvk
    /// Wine's built-in OpenGL-based Direct3D. Slowest; most compatible fallback.
    case wineD3D

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .d3dMetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wineD3D: return "WineD3D"
        }
    }

    var summary: String {
        switch self {
        case .automatic: return "Use the engine's default renderer."
        case .d3dMetal: return "Apple's Direct3D 11/12 to Metal translator. Best for most modern games."
        case .dxmt: return "Open-source Direct3D 10/11 to Metal translator. Try it when D3DMetal misbehaves on a DX11 game."
        case .dxvk: return "Direct3D 9/10/11 through Vulkan and MoltenVK. Useful for older DX9 games."
        case .wineD3D: return "Wine's OpenGL renderer. Slowest; a last-resort compatibility fallback."
        }
    }
}

/// DirectX ray tracing on D3DMetal. D3DMetal's own default is on for M3 and
/// newer and off for M1/M2, so "automatic" leaves that default alone.
enum RayTracingMode: String, Codable, CaseIterable, Identifiable {
    case automatic, on, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// Windows version a bottle reports to programs (`winecfg -v <value>`).
enum WindowsVersion: String, Codable, CaseIterable, Identifiable {
    case win11, win10, win81, win7, winxp64

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win7: return "Windows 7"
        case .winxp64: return "Windows XP (64-bit)"
        }
    }

    /// The argument `winecfg -v` accepts.
    var winecfgValue: String { rawValue }
}

/// A user-defined environment variable for every program launched in a bottle.
struct EnvironmentVariable: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

/// Per-bottle settings, mirroring CrossOver's bottle configuration.
struct BottleSettings: Codable, Equatable {
    var graphics: GraphicsBackend = .automatic
    /// Mach-semaphore synchronization (macOS's fast path; replaces esync there).
    var msync = true
    /// eventfd-style synchronization; the older fallback when msync misbehaves.
    var esync = false
    /// Render at full Retina resolution instead of scaled points.
    var highResolutionMode = false
    /// Apple's Metal Performance HUD (FPS and frame-time overlay).
    var metalHUD = false
    /// DirectX ray tracing on D3DMetal. Only applied on chips with hardware ray tracing.
    var rayTracing: RayTracingMode = .automatic
    /// Translate in-game DLSS to MetalFX upscaling (CrossOver 26+, D3DMetal or DXMT).
    var dlssMetalFX = false
    /// Ask Rosetta to advertise AVX/AVX2 to x86 programs (macOS 15 and later).
    var advertiseAVX = true
    /// Keep Wine's debug output (WINEDEBUG) instead of silencing it.
    var debugLogging = false
    /// Extra Steam switches for plain WineHQ engines (see LaunchPlanner).
    var steamCompatibilityFlags = false
    var environment: [EnvironmentVariable] = []

    init() {}

    // Decoding falls back to the property defaults above, so the defaults are
    // written once and bottles saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BottleSettings()
        graphics = (try? c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics)) ?? d.graphics
        msync = (try? c.decodeIfPresent(Bool.self, forKey: .msync)) ?? d.msync
        esync = (try? c.decodeIfPresent(Bool.self, forKey: .esync)) ?? d.esync
        highResolutionMode = (try? c.decodeIfPresent(Bool.self, forKey: .highResolutionMode)) ?? d.highResolutionMode
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        rayTracing = (try? c.decodeIfPresent(RayTracingMode.self, forKey: .rayTracing)) ?? d.rayTracing
        dlssMetalFX = (try? c.decodeIfPresent(Bool.self, forKey: .dlssMetalFX)) ?? d.dlssMetalFX
        advertiseAVX = (try? c.decodeIfPresent(Bool.self, forKey: .advertiseAVX)) ?? d.advertiseAVX
        debugLogging = (try? c.decodeIfPresent(Bool.self, forKey: .debugLogging)) ?? d.debugLogging
        steamCompatibilityFlags = (try? c.decodeIfPresent(Bool.self, forKey: .steamCompatibilityFlags)) ?? d.steamCompatibilityFlags
        environment = (try? c.decodeIfPresent([EnvironmentVariable].self, forKey: .environment)) ?? d.environment
    }
}

/// An executable the user added to a bottle's program list by hand.
struct PinnedProgram: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Host path of the .exe (or .lnk / .bat / .msi).
    var path: String
    var arguments: [String] = []
}

/// Where a bottle's prefix came from.
enum BottleOrigin: String, Codable {
    /// Created by SteamXBridge; its prefix lives in SteamXBridge's Prefixes folder.
    case owned
    /// An existing prefix (CrossOver, Whisky, a Game Porting Toolkit prefix, any
    /// folder). Removing it from SteamXBridge never deletes the prefix.
    case linked
}

/// A Wine prefix plus the settings SteamXBridge applies when running programs in it.
struct Bottle: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Absolute host path of the prefix (the directory containing drive_c).
    var prefixPath: String
    var origin: BottleOrigin = .owned
    /// For linked bottles, the app the prefix came from ("CrossOver", "Whisky", ...).
    var linkedSource: String?
    /// The engine to run programs with; nil picks the best detected engine.
    var engineID: String?
    var windowsVersion: WindowsVersion = .win10
    var settings = BottleSettings()
    var pinnedPrograms: [PinnedProgram] = []
    var createdAt = Date()

    var prefixURL: URL { URL(fileURLWithPath: prefixPath, isDirectory: true) }
    var driveC: URL { prefixURL.appendingPathComponent("drive_c", isDirectory: true) }
    /// True once Wine has initialized the prefix.
    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("system.reg").path)
    }

    init(name: String, prefixPath: String, origin: BottleOrigin = .owned) {
        self.name = name
        self.prefixPath = prefixPath
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prefixPath = try c.decode(String.self, forKey: .prefixPath)
        let d = Bottle(name: name, prefixPath: prefixPath)
        origin = (try? c.decodeIfPresent(BottleOrigin.self, forKey: .origin)) ?? d.origin
        linkedSource = try? c.decodeIfPresent(String.self, forKey: .linkedSource)
        engineID = try? c.decodeIfPresent(String.self, forKey: .engineID)
        windowsVersion = (try? c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)) ?? d.windowsVersion
        settings = (try? c.decodeIfPresent(BottleSettings.self, forKey: .settings)) ?? d.settings
        pinnedPrograms = (try? c.decodeIfPresent([PinnedProgram].self, forKey: .pinnedPrograms)) ?? d.pinnedPrograms
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? d.createdAt
    }
}
