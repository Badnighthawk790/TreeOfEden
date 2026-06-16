import Foundation

/// A small, curated database of how well popular Steam titles tolerate macOS
/// translation layers. The dominant blocker is kernel-level anti-cheat, which
/// does not run under Wine or the Game Porting Toolkit.
struct GameCompatibility {
    enum Status: String {
        case playable
        case risky
        case blocked
        case unknown

        var label: String {
            switch self {
            case .playable: return "Likely playable"
            case .risky: return "Risky / partial"
            case .blocked: return "Will not run"
            case .unknown: return "Unknown"
            }
        }
    }

    struct Entry: Equatable {
        let title: String
        let appID: String?
        /// Lowercased substring used to match the profile name when no App ID is set.
        let nameMatch: String
        let antiCheat: String?
        let status: Status
        let note: String
    }

    static let knownGames: [Entry] = [
        Entry(
            title: "Helldivers 2",
            appID: "553850",
            nameMatch: "helldivers",
            antiCheat: "nProtect GameGuard",
            status: .blocked,
            note: "GameGuard is a kernel-level anti-cheat that does not run under Wine or the Game Porting Toolkit. The game fails to launch (or kicks you out), and bypassing anti-cheat risks a permanent account ban. There is no working macOS translation path today."
        ),
        Entry(
            title: "Destiny 2",
            appID: "1085660",
            nameMatch: "destiny 2",
            antiCheat: "BattlEye (kernel)",
            status: .blocked,
            note: "Bungie blocks unsupported environments. Running under translation trips anti-cheat and leads to account bans."
        ),
        Entry(
            title: "Apex Legends",
            appID: "1172470",
            nameMatch: "apex legends",
            antiCheat: "Easy Anti-Cheat (kernel)",
            status: .blocked,
            note: "EAC kernel mode is unsupported on macOS translation layers, so multiplayer is blocked."
        ),
        Entry(
            title: "Elden Ring",
            appID: "1245620",
            nameMatch: "elden ring",
            antiCheat: "Easy Anti-Cheat",
            status: .risky,
            note: "Single-player can run with anti-cheat disabled, but online play is blocked and the pace is rough on a fanless M2 Air."
        ),
        Entry(
            title: "Cyberpunk 2077",
            appID: "1091500",
            nameMatch: "cyberpunk",
            antiCheat: nil,
            status: .playable,
            note: "No anti-cheat. Runs via GPTK/D3DMetal, but it is GPU-heavy — expect roughly 30–45 FPS at low settings with MetalFX/FSR on an M2 Air."
        ),
        Entry(
            title: "Baldur's Gate 3",
            appID: "1086940",
            nameMatch: "baldur",
            antiCheat: nil,
            status: .playable,
            note: "Has a native macOS build — prefer that over translation for the best performance and battery life."
        ),
        Entry(
            title: "Hades",
            appID: "1145360",
            nameMatch: "hades",
            antiCheat: nil,
            status: .playable,
            note: "Light and anti-cheat free. Holds a steady 60 FPS under translation, and also ships a native build."
        )
    ]

    /// Looks up a game by Steam App ID first, then by a case-insensitive name match.
    /// Returns `nil` when the title is not in the database.
    static func lookup(appID: String, name: String) -> Entry? {
        let trimmedID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedID.isEmpty, let match = knownGames.first(where: { $0.appID == trimmedID }) {
            return match
        }

        let lowerName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowerName.isEmpty else { return nil }
        return knownGames.first(where: { lowerName.contains($0.nameMatch) })
    }
}
