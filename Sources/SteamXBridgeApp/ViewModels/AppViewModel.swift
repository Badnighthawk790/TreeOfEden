#if os(macOS)
import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var profile = LaunchProfile(name: "Example Game")
    @Published var runtimeBinary = "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
    @Published var statusMessage = "Ready"

    private let service = SteamRuntimeService()

    func launchGame() {
        do {
            try service.launch(profile: profile, runtimeBinary: runtimeBinary)
            statusMessage = "Launch script started for \(profile.name)."
        } catch {
            statusMessage = error.localizedDescription
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
