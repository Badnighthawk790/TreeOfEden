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

/// Apple's two chip lines in Macs: the M series, and the A series of the
/// MacBook Neo (A18 Pro).
enum ChipFamily: String, Equatable {
    case m, a
}

/// The host Apple Silicon GPU, as far as translation layers care.
///
/// Hardware features cannot be emulated upward: hardware ray tracing and
/// hardware mesh shading arrived with M3 (and with A17 Pro in the A series)
/// and are present on every later generation. On M1/M2 the app keeps
/// hardware-only paths (DirectX ray tracing) off instead of pretending.
struct GPUStack: Equatable {
    /// M or A series; nil when the chip could not be identified (Intel Macs,
    /// Linux, unknown brand strings).
    let family: ChipFamily?
    /// The number in the chip's name: 1 for M1, 5 for M5, 18 for A18 Pro.
    let generation: Int?
    /// "Pro", "Max" or "Ultra"; nil for the base chip.
    let tier: String?
    /// The raw brand string, e.g. "Apple M2", "Apple M5 Max" or "Apple A18 Pro".
    let marketingName: String
    /// True for virtual machines (e.g. "Apple M1 (Virtual)" on CI runners), whose
    /// paravirtualized GPU does not have the physical chip's capabilities.
    let isVirtualMachine: Bool

    var isIdentified: Bool { generation != nil && !isVirtualMachine }

    /// M3 and newer, and A17 Pro and newer, share the GPU generation that
    /// added hardware ray tracing and mesh shading.
    private var hasRayTracingEraGPU: Bool {
        guard isIdentified, let generation else { return false }
        switch family {
        case .m: return generation >= 3
        case .a: return generation >= 17
        case nil: return false
        }
    }

    var hasHardwareRayTracing: Bool { hasRayTracingEraGPU }
    var hasHardwareMeshShading: Bool { hasRayTracingEraGPU }
    /// Apple documents Dynamic Caching for M3 and newer Macs.
    var hasDynamicCaching: Bool { family == .m && hasRayTracingEraGPU }
    /// MetalFX upscaling is available on every Apple Silicon Mac.
    var supportsMetalFX: Bool { generation != nil }

    /// The slowest Apple Silicon GPUs: every A-series Mac and the base M1 and
    /// M2. Games here need a lower render resolution, upscaling and a frame
    /// cap to stay smooth, so new bottles start with those.
    var isEntryLevel: Bool {
        guard let generation else { return false }
        switch family {
        case .a: return true
        case .m: return generation <= 2 && tier == nil
        case nil: return false
        }
    }

    /// A short label for the UI, e.g. "Entry-level GPU (no hardware ray tracing)".
    var classLabel: String {
        guard generation != nil else { return "Unidentified GPU" }
        if isVirtualMachine { return "Virtual machine GPU" }
        let rayTracing = hasHardwareRayTracing ? "hardware ray tracing" : "no hardware ray tracing"
        if isEntryLevel { return "Entry-level GPU (\(rayTracing))" }
        return hasHardwareRayTracing ? "M3-class GPU (hardware ray tracing)" : "M1/M2-class GPU (no hardware ray tracing)"
    }

    /// Per-feature comparison against current Apple Silicon, for the UI.
    var featureStatuses: [GPUFeatureStatus] {
        [
            GPUFeatureStatus(
                feature: "Hardware ray tracing",
                status: hasHardwareRayTracing
                    ? "Available. DirectX ray tracing (DXR) can be enabled per bottle on D3DMetal."
                    : (isIdentified
                        ? "Not on this chip (M3, A17 Pro and newer). DXR stays off; turn ray-traced effects off in game settings."
                        : "Could not confirm on this Mac, so DXR stays off."),
                isAvailable: hasHardwareRayTracing
            ),
            GPUFeatureStatus(
                feature: "Dynamic Caching",
                status: hasDynamicCaching
                    ? "Available. The GPU allocates on-chip memory dynamically."
                    : (family == .a
                        ? "Apple documents it for M3 and newer Macs only."
                        : "Not on this chip (M3 and newer). It is a hardware feature; software cannot add it."),
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
                    ? "Available. On DXMT, turn on MetalFX upscaling; on D3DMetal, enable \"DLSS → MetalFX\" and pick DLSS in the game. A game's own FSR/XeSS works too."
                    : "Could not confirm on this Mac.",
                isAvailable: supportsMetalFX
            ),
        ]
    }

    /// Detects the host chip from `machdep.cpu.brand_string`.
    static func detect() -> GPUStack {
        parse(brand: hardwareBrandString())
    }

    /// Parses a brand string such as "Apple M1", "Apple M2 Pro", "Apple M5 Max",
    /// "Apple A18 Pro" or "Apple M1 (Virtual)". Separated from `detect()` so it
    /// is testable.
    static func parse(brand: String) -> GPUStack {
        let name = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let isVirtual = name.localizedCaseInsensitiveContains("virtual")
        var family: ChipFamily?
        var generation: Int?
        var tier: String?

        for (prefix, candidate) in [("Apple M", ChipFamily.m), ("Apple A", .a)] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            let tail = rest.dropFirst(digits.count)
            guard let number = Int(digits), number > 0, tail.isEmpty || tail.first == " " else { continue }
            family = candidate
            generation = number
            let word = tail.split(separator: " ").first.map(String.init)
            if let word, ["Pro", "Max", "Ultra"].contains(word) { tier = word }
        }

        return GPUStack(
            family: family,
            generation: generation,
            tier: tier,
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
