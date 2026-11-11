import Foundation

/// Frame-rate limits a display can pace evenly. DXMT's limiter presents each
/// frame on a display refresh, so a limit that does not divide the refresh
/// rate falls to the next one that does (40 fps on a 60 Hz panel runs at 30).
enum FrameRateCap {
    /// Whole divisors of the refresh rate from 24 fps up, lowest first:
    /// 60 Hz gives 30 and 60; 120 Hz gives 24, 30, 40, 60 and 120.
    static func choices(refreshRate: Int) -> [Int] {
        guard refreshRate >= 24 else { return [] }
        return (1...refreshRate / 24).compactMap { divisor in
            refreshRate % divisor == 0 ? refreshRate / divisor : nil
        }.sorted()
    }

    /// The rate a limit really runs at on this display: the highest evenly
    /// paced rate that does not exceed it.
    static func effectiveRate(limit: Int, refreshRate: Int) -> Int {
        guard limit > 0 else { return 0 }
        return choices(refreshRate: refreshRate).last { $0 <= limit } ?? limit
    }
}

/// Something about this Mac or this bottle that costs speed, with what to do.
struct PerformanceNote: Identifiable, Equatable {
    enum Kind {
        /// Slowing games down right now.
        case warning
        /// A setting that would help on this Mac.
        case tip
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
}

/// Settings and advice for slow Macs: the base M1 and M2, and A-series Macs
/// such as the MacBook Neo (2 performance cores, 8 GB, no fan).
enum PerformanceTuning {
    /// True when the bottle's Direct3D 10/11 runs on DXMT, whose upscaler and
    /// frame-rate limit then apply.
    static func runsDXMT(_ settings: BottleSettings, engine: WineEngine) -> Bool {
        engine.isCrossOver ? settings.graphics == .dxmt : engine.layer(for: settings.graphics)?.layer == .dxmt
    }

    /// `settings` tuned for an entry-level Mac:
    /// - MetalFX upscaling at 2× on a Retina display. With High Resolution
    ///   Mode off a game renders at the desktop's point size (1440×900 on a
    ///   MacBook Air) and MetalFX turns that into the full Retina image; any
    ///   lower in-game resolution is upscaled the same way.
    /// - A frame-rate limit at the display's refresh rate. Without one DXMT
    ///   renders menus and light scenes at hundreds of frames per second, and
    ///   a fanless Mac heats up and slows down before the game needs it.
    /// - High Resolution Mode (four times the pixels) and detailed logging off.
    static func optimized(_ settings: BottleSettings, engine: WineEngine, display: DisplayProfile) -> BottleSettings {
        var result = settings
        result.highResolutionMode = false
        result.debugLogging = false
        if runsDXMT(result, engine: engine) {
            result.metalFXUpscaling = display.isRetina
            result.metalFXScale = 2.0
            result.frameRateLimit = FrameRateCap.choices(refreshRate: display.refreshRate).last ?? 0
        }
        return result
    }

    /// What is slowing this bottle down, and what would speed it up.
    static func notes(system: SystemProfile, conditions: SystemConditions, settings: BottleSettings,
                      engine: WineEngine?, display: DisplayProfile) -> [PerformanceNote] {
        var notes: [PerformanceNote] = []
        if conditions.lowPowerMode {
            notes.append(PerformanceNote(
                id: "low-power", kind: .warning, title: "Low Power Mode is on",
                detail: "macOS is holding back the processor and graphics. Turn it off in System Settings > Battery while you play."))
        }
        if conditions.thermal >= .serious {
            notes.append(PerformanceNote(
                id: "thermal", kind: .warning, title: "This Mac is hot and has slowed itself down",
                detail: "Give it a minute to cool, and keep it on a hard surface. A frame-rate limit or a lower in-game resolution keeps it from heating up again."))
        }
        if settings.debugLogging {
            notes.append(PerformanceNote(
                id: "logging", kind: .warning, title: "Detailed Wine logging is on",
                detail: "It slows every program in this bottle. Turn it off in Settings when you are done troubleshooting."))
        }
        if settings.highResolutionMode, system.gpu.isEntryLevel {
            notes.append(PerformanceNote(
                id: "retina", kind: .warning, title: "High Resolution Mode is on",
                detail: "Games render four times the pixels, which is too much for this Mac's graphics. Turn it off and use MetalFX upscaling for a sharp picture instead."))
        }

        guard system.gpu.isEntryLevel || system.isMemoryConstrained else { return notes }
        if let engine, runsDXMT(settings, engine: engine) {
            if !settings.metalFXUpscaling, display.isRetina {
                notes.append(PerformanceNote(
                    id: "metalfx", kind: .tip, title: "Turn on MetalFX upscaling",
                    detail: "Games then render at a lower resolution and MetalFX sharpens the picture to the display's full resolution."))
            }
            if settings.frameRateLimit == 0 {
                notes.append(PerformanceNote(
                    id: "frame-limit", kind: .tip, title: "Set a frame-rate limit",
                    detail: "Without one, menus and light scenes render far more frames than the display shows, which heats the Mac until it slows down."))
            }
        }
        if system.isMemoryConstrained {
            notes.append(PerformanceNote(
                id: "memory", kind: .tip, title: "\(system.memoryGB) GB of memory is shared with the game",
                detail: "macOS, Steam, the game and its graphics all use the same memory. Quit browsers and other apps before playing, and prefer medium or low texture quality."))
        }
        if let cores = system.performanceCores, cores <= 2 {
            notes.append(PerformanceNote(
                id: "cores", kind: .tip, title: "\(cores) performance cores",
                detail: "Anything else that is busy takes speed from the game. Pause Steam downloads and close other apps while you play."))
        }
        return notes
    }
}
