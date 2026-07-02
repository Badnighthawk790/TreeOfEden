import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Apple Silicon generation of the host machine, as it relates to the GPU
/// feature set available to translation layers.
enum AppleGPUFamily: String, Codable {
    case m1, m2, m3, m4
    case unknown
}

/// How one M4-era GPU feature maps onto the current machine, for display.
struct GPUFeatureStatus: Identifiable {
    let feature: String
    let status: String
    /// True when the chip has the dedicated hardware; false when the closest
    /// software approximation is used instead.
    let isHardware: Bool

    var id: String { feature }
}

/// A snapshot of the host GPU stack: which M4-era hardware features exist on
/// this chip, and which have to be approximated in software. Hardware cannot
/// be emulated upward — M3 introduced the silicon for Dynamic Caching, ray
/// tracing, and mesh shading — so on M1/M2 the app enables the closest
/// software levers instead and keeps hardware-dependent paths disabled.
struct GPUStack: Equatable {
    let family: AppleGPUFamily
    let marketingName: String

    /// Dedicated ray-tracing cores arrived with M3.
    var hasHardwareRayTracing: Bool { family == .m3 || family == .m4 }

    /// Dynamic Caching (hardware-managed on-chip memory allocation) arrived with M3.
    var hasDynamicCaching: Bool { family == .m3 || family == .m4 }

    /// Hardware-accelerated mesh shading arrived with M3; M1/M2 run the Metal
    /// mesh-shader API without the dedicated hardware path.
    var hasHardwareMeshShading: Bool { family == .m3 || family == .m4 }

    /// MetalFX temporal upscaling runs on all Apple Silicon generations.
    var supportsMetalFXTemporal: Bool { family != .unknown }

    /// Per-feature comparison against the M4 GPU stack, for the UI.
    var featureStatuses: [GPUFeatureStatus] {
        [
            GPUFeatureStatus(
                feature: "Dynamic Caching",
                status: hasDynamicCaching
                    ? "Native on this chip — on-chip memory is allocated by hardware."
                    : "Approximated: Metal argument buffers + heap-backed allocations cut per-draw binding and memory overhead on M1/M2.",
                isHardware: hasDynamicCaching
            ),
            GPUFeatureStatus(
                feature: "Ray tracing",
                status: hasHardwareRayTracing
                    ? "Native RT cores — DXR translation can be enabled."
                    : "No RT cores on this chip. DXR stays disabled: the software fallback collapses the frame rate instead of improving it.",
                isHardware: hasHardwareRayTracing
            ),
            GPUFeatureStatus(
                feature: "Mesh shading",
                status: hasHardwareMeshShading
                    ? "Hardware-accelerated on this chip."
                    : "Metal mesh-shader API is available, without the dedicated M3/M4 hardware path.",
                isHardware: hasHardwareMeshShading
            ),
            GPUFeatureStatus(
                feature: "MetalFX temporal upscaling",
                status: supportsMetalFXTemporal
                    ? "Available — the main software lever for M4-class output from a smaller GPU. Render at ~60–77% and upscale."
                    : "Unknown chip — availability cannot be confirmed.",
                isHardware: supportsMetalFXTemporal
            )
        ]
    }

    /// Detects the host chip. Returns `.unknown` off-macOS and in virtualized
    /// CI runners (whose brand string is not an "Apple M…" name).
    static func detect() -> GPUStack {
        parse(brand: hardwareBrandString())
    }

    /// Pure parsing of a `machdep.cpu.brand_string` value; separated from
    /// `detect()` so it is testable on any platform.
    static func parse(brand: String) -> GPUStack {
        let name = brand.trimmingCharacters(in: .whitespacesAndNewlines)

        func matches(_ generation: String) -> Bool {
            guard name.hasPrefix(generation) else { return false }
            let rest = name.dropFirst(generation.count)
            return rest.isEmpty || rest.first == " "
        }

        let family: AppleGPUFamily
        if matches("Apple M1") { family = .m1 }
        else if matches("Apple M2") { family = .m2 }
        else if matches("Apple M3") { family = .m3 }
        else if matches("Apple M4") { family = .m4 }
        else { family = .unknown }

        return GPUStack(family: family, marketingName: name.isEmpty ? "Unknown CPU" : name)
    }

    static func hardwareBrandString() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
        #else
        return ""
        #endif
    }
}
