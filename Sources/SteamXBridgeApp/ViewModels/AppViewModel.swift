#if os(macOS)
import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var profile = LaunchProfile(name: "Example Game")
    @Published var runtimeBinary = "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
    @Published var statusMessage = "Ready"
    @Published var backgroundIntervalSeconds = 45

    private let service = SteamRuntimeService()
    private let backgroundAgentService = BackgroundAgentService()

    func launchGame() {
        do {
            try service.launch(profile: profile, runtimeBinary: runtimeBinary)
            statusMessage = profile.gameExecutablePath.isEmpty
                ? "Sent launch command to Steam for App ID \(profile.steamAppID)."
                : "Launch script started for \(profile.name)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func queueBackgroundLaunch() {
        do {
            try service.queueBackgroundLaunch(profile: profile, runtimeBinary: runtimeBinary)
            statusMessage = "Queued \(profile.name) for low-resource background launch."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installBackgroundAgent() {
        do {
            try backgroundAgentService.install(intervalSeconds: backgroundIntervalSeconds)
            statusMessage = "Background helper enabled. SteamXBridge now checks for queued launches every \(backgroundIntervalSeconds)s."
        } catch {
            statusMessage = "Failed to enable helper: \(error.localizedDescription)"
        }
    }

    func removeBackgroundAgent() {
        do {
            try backgroundAgentService.uninstall()
            statusMessage = "Background helper disabled."
        } catch {
            statusMessage = "Failed to disable helper: \(error.localizedDescription)"
        }
    }

    func saveProfile(to url: URL) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url)
        statusMessage = "Saved profile to \(url.lastPathComponent)."
    }

    func loadProfile(from url: URL) throws {
        let data = try Data(contentsOf: url)
        profile = try JSONDecoder().decode(LaunchProfile.self, from: data)
        statusMessage = "Loaded profile \(profile.name)."
    }
}
#endif
