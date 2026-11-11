import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What this Mac can give a game beyond the chip's name: memory and core counts.
struct SystemProfile: Equatable {
    var gpu: GPUStack
    /// Installed memory in bytes. On Apple Silicon it is shared between macOS,
    /// every app and the GPU.
    var memoryBytes: UInt64
    /// Performance and efficiency core counts; nil when unknown.
    var performanceCores: Int?
    var efficiencyCores: Int?

    var memoryGB: Int { Int((Double(memoryBytes) / 1_073_741_824).rounded()) }

    /// 8 GB or less: macOS, Steam, a Windows game and its textures barely fit.
    var isMemoryConstrained: Bool { memoryBytes > 0 && memoryGB <= 8 }

    /// "8 GB · 2 performance + 4 efficiency cores".
    var summary: String {
        var parts: [String] = []
        if memoryBytes > 0 { parts.append("\(memoryGB) GB") }
        if let performanceCores, let efficiencyCores {
            parts.append("\(performanceCores) performance + \(efficiencyCores) efficiency cores")
        }
        return parts.joined(separator: " · ")
    }

    static func detect() -> SystemProfile {
        SystemProfile(
            gpu: .detect(),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            // Level 0 is the performance cores, level 1 the efficiency cores.
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu")
        )
    }

    private static func sysctlInt(_ name: String) -> Int? {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
        #else
        return nil
        #endif
    }
}

/// The display games will appear on, as far as the launcher needs to know.
struct DisplayProfile: Equatable {
    /// Refresh rate in Hz.
    var refreshRate = 60
    /// Pixels per point: 2 on Retina displays, 1 on most external monitors.
    var scale = 2.0
    /// The desktop size in points, which is what Windows programs see as the
    /// screen resolution while High Resolution Mode is off.
    var width = 0
    var height = 0

    var isRetina: Bool { scale >= 2 }
}

/// What macOS is doing right now that slows games down.
struct SystemConditions: Equatable {
    enum Thermal: Int, Comparable {
        case nominal, fair, serious, critical
        static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    var lowPowerMode = false
    var thermal: Thermal = .nominal
}
