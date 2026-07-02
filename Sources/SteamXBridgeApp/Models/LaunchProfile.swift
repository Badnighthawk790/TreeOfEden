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
    /// Enables the software levers that approximate M3/M4 GPU-stack gains on
    /// older chips: Metal argument buffers, prefilled command buffers,
    /// heap-backed memory, and parallel shader compilation.
    var useChipOptimizations: Bool
    /// User intent to enable DXR translation. Only honored when the chip has
    /// hardware ray tracing (M3/M4); forced off on M1/M2.
    var allowRayTracing: Bool
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
        useChipOptimizations: Bool = true,
        allowRayTracing: Bool = false,
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
        self.useChipOptimizations = useChipOptimizations
        self.allowRayTracing = allowRayTracing
        self.customEnv = customEnv
    }

    /// Decodes with per-field defaults so profiles saved by older versions of
    /// the app (before a field existed) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        steamAppID = try c.decodeIfPresent(String.self, forKey: .steamAppID) ?? ""
        gameExecutablePath = try c.decodeIfPresent(String.self, forKey: .gameExecutablePath) ?? ""
        winePrefixPath = try c.decodeIfPresent(String.self, forKey: .winePrefixPath) ?? ""
        backend = try c.decodeIfPresent(TranslationBackend.self, forKey: .backend) ?? .gptkD3DMetal
        upscaler = try c.decodeIfPresent(Upscaler.self, forKey: .upscaler) ?? .metalFX
        resolutionScalePercent = try c.decodeIfPresent(Int.self, forKey: .resolutionScalePercent) ?? 77
        syncPrimitive = try c.decodeIfPresent(SyncPrimitive.self, forKey: .syncPrimitive) ?? .msync
        useAsyncShaders = try c.decodeIfPresent(Bool.self, forKey: .useAsyncShaders) ?? true
        frameLimit = try c.decodeIfPresent(Int.self, forKey: .frameLimit) ?? 60
        showFPSOverlay = try c.decodeIfPresent(Bool.self, forKey: .showFPSOverlay) ?? false
        useChipOptimizations = try c.decodeIfPresent(Bool.self, forKey: .useChipOptimizations) ?? true
        allowRayTracing = try c.decodeIfPresent(Bool.self, forKey: .allowRayTracing) ?? false
        customEnv = try c.decodeIfPresent(String.self, forKey: .customEnv) ?? ""
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

    /// Environment for the host machine's detected chip.
    var launchEnvironment: [String: String] {
        launchEnvironment(gpu: .detect())
    }

    /// Environment variables passed to the runtime. Only variables that actually
    /// apply to the selected backend are emitted; `customEnv` overrides everything.
    /// Chip-dependent features (ray tracing) are gated on `gpu`.
    func launchEnvironment(gpu: GPUStack) -> [String: String] {
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
            if useChipOptimizations {
                // Make sure no Metal debug/validation overhead sneaks into the
                // hot path launched from a GUI context.
                env["MTL_SHADER_VALIDATION"] = "0"
                env["MTL_DEBUG_LAYER"] = "0"
            }
            // DXR translation only pays off on chips with RT cores (M3/M4). On
            // M1/M2 the software fallback collapses the frame rate, so it is
            // forced off regardless of the user toggle.
            env["D3DM_SUPPORT_DXR"] = (allowRayTracing && gpu.hasHardwareRayTracing) ? "1" : "0"
        case .wineDXVK:
            env["DXVK_ASYNC"] = useAsyncShaders ? "1" : "0"
            env["DXVK_STATE_CACHE"] = "1"
            env["DXVK_FRAME_RATE"] = "\(frameLimit)"
            env["DXVK_HUD"] = showFPSOverlay ? "fps,frametimes" : "0"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
            env["MVK_CONFIG_FAST_MATH_ENABLED"] = "1"
            if useChipOptimizations {
                // The closest software stand-ins for M3/M4 hardware gains:
                // argument buffers cut per-draw-call binding overhead,
                env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "1"
                // heap-backed allocations approximate hardware-managed memory,
                env["MVK_CONFIG_USE_MTLHEAP"] = "1"
                // immediate command-buffer encoding overlaps CPU/GPU work,
                env["MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"] = "2"
                // and pipeline compiles fan out across all CPU cores.
                env["MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION"] = "1"
            }
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
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            // The key is emitted unescaped into the generated shell script, so only
            // accept legal env identifiers — this prevents a crafted custom key such
            // as `FOO; rm -rf ~` from injecting commands.
            if Self.isValidEnvName(key), !value.isEmpty {
                env[key] = value
            }
        }

        return env
    }

    /// True when `name` is a legal environment-variable identifier: an ASCII
    /// letter or underscore followed by ASCII letters, digits, or underscores.
    static func isValidEnvName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else { return false }
        func isAlpha(_ v: UInt32) -> Bool { (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 }
        func isDigit(_ v: UInt32) -> Bool { v >= 48 && v <= 57 }
        guard isAlpha(first.value) else { return false }
        return scalars.allSatisfy { isAlpha($0.value) || isDigit($0.value) }
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
