import Foundation

/// The translation stack used to run a Windows/x86 game on Apple Silicon.
enum TranslationBackend: String, Codable, CaseIterable, Identifiable {
    /// Apple Game Porting Toolkit: Wine + D3DMetal (Direct3D 11/12 → Metal) + Rosetta 2.
    case gptkD3DMetal
    /// Wine + DXVK (Direct3D → Vulkan) running on Metal via MoltenVK.
    case wineDXVK

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptkD3DMetal: return "Apple Game Porting Toolkit (D3DMetal)"
        case .wineDXVK: return "Wine + DXVK (MoltenVK)"
        }
    }

    var summary: String {
        switch self {
        case .gptkD3DMetal:
            return "Best for modern Direct3D 11/12 games on Apple Silicon. Translates D3D directly to Metal with the lowest overhead."
        case .wineDXVK:
            return "Maps Direct3D to Vulkan (DXVK) and then to Metal (MoltenVK). A useful fallback for some older or Vulkan-native titles."
        }
    }
}

/// Upscaling strategy used to gain frames by rendering below native resolution.
enum Upscaler: String, Codable, CaseIterable, Identifiable {
    case none
    case fsr
    case metalFX

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Off (native resolution)"
        case .fsr: return "AMD FSR (Wine fullscreen upscaling)"
        case .metalFX: return "MetalFX (Game Porting Toolkit)"
        }
    }
}

/// Wine synchronization primitive. `msync` is the fastest on modern macOS.
enum SyncPrimitive: String, Codable, CaseIterable, Identifiable {
    case msync
    case esync
    case fsync
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .msync: return "msync (recommended on modern macOS)"
        case .esync: return "esync"
        case .fsync: return "fsync"
        case .none: return "Off"
        }
    }
}

struct LaunchProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var steamAppID: String
    var gameExecutablePath: String
    var winePrefixPath: String
    var backend: TranslationBackend
    var upscaler: Upscaler
    /// Internal render resolution as a percentage of the display (50–100).
    var resolutionScalePercent: Int
    var syncPrimitive: SyncPrimitive
    var useAsyncShaders: Bool
    var frameLimit: Int
    var showFPSOverlay: Bool
    var customEnv: String

    init(
        id: UUID = UUID(),
        name: String = "",
        steamAppID: String = "",
        gameExecutablePath: String = "",
        winePrefixPath: String = "",
        backend: TranslationBackend = .gptkD3DMetal,
        upscaler: Upscaler = .metalFX,
        resolutionScalePercent: Int = 77,
        syncPrimitive: SyncPrimitive = .msync,
        useAsyncShaders: Bool = true,
        frameLimit: Int = 60,
        showFPSOverlay: Bool = false,
        customEnv: String = ""
    ) {
        self.id = id
        self.name = name
        self.steamAppID = steamAppID
        self.gameExecutablePath = gameExecutablePath
        self.winePrefixPath = winePrefixPath
        self.backend = backend
        self.upscaler = upscaler
        self.resolutionScalePercent = resolutionScalePercent
        self.syncPrimitive = syncPrimitive
        self.useAsyncShaders = useAsyncShaders
        self.frameLimit = frameLimit
        self.showFPSOverlay = showFPSOverlay
        self.customEnv = customEnv
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gameExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Wine fullscreen-FSR sharpness/strength (0 = sharpest, 5 = softest). Lower
    /// render scales need a higher strength to fill the screen cleanly.
    var fsrStrength: Int {
        min(max((100 - resolutionScalePercent) / 10, 0), 5)
    }

    /// Environment variables passed to the runtime. Only variables that actually
    /// apply to the selected backend are emitted; `customEnv` overrides everything.
    var launchEnvironment: [String: String] {
        var env: [String: String] = [
            // Silence Wine logging to shave overhead off a fanless chip.
            "WINEDEBUG": "-all"
        ]

        switch syncPrimitive {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .fsync: env["WINEFSYNC"] = "1"
        case .none: break
        }

        switch backend {
        case .gptkD3DMetal:
            // Many modern titles probe for AVX/AVX2; Rosetta only advertises it on request.
            env["ROSETTA_ADVERTISE_AVX"] = "1"
            env["MTL_HUD_ENABLED"] = showFPSOverlay ? "1" : "0"
        case .wineDXVK:
            env["DXVK_ASYNC"] = useAsyncShaders ? "1" : "0"
            env["DXVK_STATE_CACHE"] = "1"
            env["DXVK_FRAME_RATE"] = "\(frameLimit)"
            env["DXVK_HUD"] = showFPSOverlay ? "fps,frametimes" : "0"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
            env["MVK_CONFIG_FAST_MATH_ENABLED"] = "1"
        }

        // Wine's fullscreen FSR upscales the presented surface regardless of the D3D
        // backend, so it is available on both paths. MetalFX is a D3DMetal feature
        // toggled in the runtime's settings (see `setupReminders`).
        if upscaler == .fsr {
            env["WINE_FULLSCREEN_FSR"] = "1"
            env["WINE_FULLSCREEN_FSR_STRENGTH"] = "\(fsrStrength)"
        }

        for line in customEnv.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        return env
    }

    /// Configuration mistakes that would prevent the chosen settings from working.
    var validationWarnings: [String] {
        var warnings: [String] = []
        if upscaler == .metalFX && backend != .gptkD3DMetal {
            warnings.append("MetalFX upscaling requires the Game Porting Toolkit (D3DMetal) backend. Switch the backend, or choose FSR instead.")
        }
        return warnings
    }

    /// Steps the app cannot perform for you (in-game or runtime settings).
    var setupReminders: [String] {
        var notes: [String] = []
        switch backend {
        case .gptkD3DMetal:
            notes.append("D3DMetal has no env-var frame limiter — cap FPS to \(frameLimit) in-game or rely on vsync.")
            if upscaler == .metalFX {
                notes.append("Enable MetalFX in your runtime's D3DMetal settings (CrossOver/Whisky) and set the in-game resolution to about \(resolutionScalePercent)%.")
            }
        case .wineDXVK:
            notes.append("DXVK caps the frame rate at \(frameLimit) FPS and caches shaders to cut first-run stutter.")
        }
        if upscaler == .fsr {
            notes.append("Set the in-game resolution to about \(resolutionScalePercent)% and let Wine FSR upscale to native for extra frames.")
        }
        return notes
    }
}
