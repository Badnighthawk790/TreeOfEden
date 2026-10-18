import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How one GPU feature maps onto the current machine, for display.
struct GPUFeatureStatus: Identifiable, Equatable {
    let feature: String
    let status: String
    /// True when this Mac has the hardware for the feature.
    let isAvailable: Bool

    var id: String { feature }
}

/// The host Apple Silicon GPU, as far as translation layers care.
///
/// Hardware features cannot be emulated upward: Dynamic Caching, hardware ray
/// tracing and hardware mesh shading arrived with M3 and are present on every
/// later generation. On M1/M2 the app keeps hardware-only paths (DirectX ray
/// tracing) off instead of pretending.
struct GPUStack: Equatable {
    /// Apple M-series generation: 1 for M1, 5 for M5, and so on. Nil when the
    /// chip could not be identified (Intel Macs, Linux, unknown brand strings).
    let generation: Int?
    /// The raw brand string, e.g. "Apple M2" or "Apple M5 Max".
    let marketingName: String
    /// True for virtual machines (e.g. "Apple M1 (Virtual)" on CI runners), whose
    /// paravirtualized GPU does not have the physical chip's capabilities.
    let isVirtualMachine: Bool

    var isIdentified: Bool { generation != nil && !isVirtualMachine }

    private var hasM3ClassGPU: Bool { isIdentified && (generation ?? 0) >= 3 }

    var hasHardwareRayTracing: Bool { hasM3ClassGPU }
    var hasDynamicCaching: Bool { hasM3ClassGPU }
    var hasHardwareMeshShading: Bool { hasM3ClassGPU }
    /// MetalFX upscaling is available on every Apple Silicon Mac.
    var supportsMetalFX: Bool { generation != nil }

    /// A short label for the UI, e.g. "Apple M2 · M1/M2-class GPU".
    var classLabel: String {
        guard let generation else { return "Unidentified GPU" }
        if isVirtualMachine { return "Virtual machine GPU" }
        return generation >= 3 ? "M3-class GPU (hardware ray tracing)" : "M1/M2-class GPU (no hardware ray tracing)"
    }

    /// Per-feature comparison against current Apple Silicon, for the UI.
    var featureStatuses: [GPUFeatureStatus] {
        [
            GPUFeatureStatus(
                feature: "Hardware ray tracing",
                status: hasHardwareRayTracing
                    ? "Available. DirectX ray tracing (DXR) can be enabled per bottle on D3DMetal."
                    : (isIdentified
                        ? "Not on this chip (M3 and newer). DXR stays off; turn ray-traced effects off in game settings."
                        : "Could not confirm on this Mac, so DXR stays off."),
                isAvailable: hasHardwareRayTracing
            ),
            GPUFeatureStatus(
                feature: "Dynamic Caching",
                status: hasDynamicCaching
                    ? "Available. The GPU allocates on-chip memory dynamically."
                    : "Not on this chip (M3 and newer). It is a hardware feature; software cannot add it.",
                isAvailable: hasDynamicCaching
            ),
            GPUFeatureStatus(
                feature: "Hardware mesh shading",
                status: hasHardwareMeshShading
                    ? "Available."
                    : "Mesh shaders still run, without M3-class hardware acceleration.",
                isAvailable: hasHardwareMeshShading
            ),
            GPUFeatureStatus(
                feature: "MetalFX upscaling",
                status: supportsMetalFX
                    ? "Available. On D3DMetal, enable \"DLSS → MetalFX\" and pick DLSS in the game, or use the game's own FSR/XeSS."
                    : "Could not confirm on this Mac.",
                isAvailable: supportsMetalFX
            ),
        ]
    }

    /// Detects the host chip from `machdep.cpu.brand_string`.
    static func detect() -> GPUStack {
        parse(brand: hardwareBrandString())
    }

    /// Parses a brand string such as "Apple M1", "Apple M2 Pro", "Apple M5 Max"
    /// or "Apple M1 (Virtual)". Separated from `detect()` so it is testable.
    static func parse(brand: String) -> GPUStack {
        let name = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let isVirtual = name.localizedCaseInsensitiveContains("virtual")
        var generation: Int?

        let prefix = "Apple M"
        if name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            let tail = rest.dropFirst(digits.count)
            if let number = Int(digits), number > 0, tail.isEmpty || tail.first == " " {
                generation = number
            }
        }

        return GPUStack(
            generation: generation,
            marketingName: name.isEmpty ? "Unknown CPU" : name,
            isVirtualMachine: isVirtual
        )
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
