import Foundation

/// One-tap tuning targets sized for the fanless M2 MacBook Air's thermal envelope.
enum PerformancePreset: String, CaseIterable, Identifiable {
    case batterySaver
    case balanced60
    case maxQuality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .batterySaver: return "Battery Saver (30 FPS)"
        case .balanced60: return "Balanced 60 (recommended)"
        case .maxQuality: return "Max Quality"
        }
    }

    var summary: String {
        switch self {
        case .batterySaver:
            return "30 FPS cap with aggressive upscaling — coolest and longest battery life on a fanless Air."
        case .balanced60:
            return "60 FPS target with upscaling — the sweet spot for most playable games on the M2 Air."
        case .maxQuality:
            return "Native resolution, no upscaling — best image, but the Air will throttle in long sessions."
        }
    }

    /// Applies the preset to a profile, keeping an upscaler that suits the backend.
    func apply(to profile: inout LaunchProfile) {
        switch self {
        case .batterySaver:
            profile.frameLimit = 30
            profile.resolutionScalePercent = 60
            profile.upscaler = profile.backend == .wineDXVK ? .fsr : .metalFX
            profile.showFPSOverlay = false
        case .balanced60:
            profile.frameLimit = 60
            profile.resolutionScalePercent = 77
            profile.upscaler = profile.backend == .wineDXVK ? .fsr : .metalFX
        case .maxQuality:
            profile.frameLimit = 60
            profile.resolutionScalePercent = 100
            profile.upscaler = .none
        }
    }
}
