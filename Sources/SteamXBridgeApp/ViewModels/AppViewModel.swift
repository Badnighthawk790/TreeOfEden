#if os(macOS)
import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var profile = LaunchProfile(name: "Example Game")
    @Published var runtimeBinary = "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
    @Published var statusMessage = "Ready"

    @Published var steamRootPath = SteamLibraryScanner.defaultSteamRoot().path
    @Published var discoveredApps: [SteamApp] = []
    @Published var selectedAppID: String?

    private let service = SteamRuntimeService()

    /// Known-compatibility entry for the current game, if any.
    var compatibility: GameCompatibility.Entry? {
        GameCompatibility.lookup(appID: profile.steamAppID, name: profile.name)
    }

    func applyPreset(_ preset: PerformancePreset) {
        preset.apply(to: &profile)
        statusMessage = "Applied \(preset.displayName) preset."
    }

    func scanSteamLibrary() {
        let scanner = SteamLibraryScanner(steamRoot: URL(fileURLWithPath: steamRootPath))
        let apps = scanner.installedApps()
        discoveredApps = apps
        selectedAppID = apps.first?.appID
        statusMessage = apps.isEmpty
            ? "No installed games found. Check the Steam path."
            : "Found \(apps.count) installed game(s)."
    }

    func useSelectedApp() {
        guard let id = selectedAppID,
              let app = discoveredApps.first(where: { $0.appID == id }) else { return }
        makeProfile(from: app)
    }

    /// Builds a launch profile from a discovered game, guessing its executable.
    func makeProfile(from app: SteamApp) {
        let scanner = SteamLibraryScanner(steamRoot: URL(fileURLWithPath: steamRootPath))
        let candidates = scanner.executableCandidates(for: app)
        var newProfile = LaunchProfile(name: app.name, steamAppID: app.appID)
        newProfile.gameExecutablePath = candidates.first ?? app.installPath
        profile = newProfile

        if let compat = GameCompatibility.lookup(appID: app.appID, name: app.name), compat.status == .blocked {
            statusMessage = "Loaded \(app.name) — but it will not run: \(compat.note)"
        } else if candidates.isEmpty {
            statusMessage = "Loaded \(app.name). Set the .exe path manually."
        } else {
            statusMessage = "Loaded \(app.name) with \(candidates.count) executable candidate(s)."
        }
    }

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
