import Foundation

/// A small, curated record of how specific Steam titles fare on Apple Silicon,
/// with the bottle settings known to work. Ratings change with game patches and
/// engine releases, so every entry records when it was last checked.
enum GameCompatibility {
    enum Rating: String {
        /// A native macOS version exists; install that instead of translating.
        case native
        case runsWell
        case playable
        /// Kernel anti-cheat or similar blocks it on every Mac engine.
        case blocked

        var label: String {
            switch self {
            case .native: return "Native Mac version"
            case .runsWell: return "Runs well"
            case .playable: return "Playable with caveats"
            case .blocked: return "Does not run"
            }
        }
    }

    /// Bottle settings known to work for a title. Nil fields are left alone.
    struct Recommendation: Equatable {
        var graphics: GraphicsBackend?
        var msync: Bool?
        var advertiseAVX: Bool?
        var highResolutionMode: Bool?

        func apply(to settings: inout BottleSettings) {
            if let graphics { settings.graphics = graphics }
            if let msync { settings.msync = msync }
            if let advertiseAVX { settings.advertiseAVX = advertiseAVX }
            if let highResolutionMode { settings.highResolutionMode = highResolutionMode }
        }
    }

    struct Entry: Equatable, Identifiable {
        let appID: String
        let title: String
        let rating: Rating
        let antiCheat: String?
        /// Lowest CrossOver major version that runs it; nil when any engine may work.
        let minimumCrossOverMajor: Int?
        let recommendation: Recommendation?
        let note: String
        /// When the entry was last checked against public reports (YYYY-MM).
        let asOf: String

        var id: String { appID }
    }

    static let entries: [Entry] = [
        Entry(
            appID: "553850",
            title: "HELLDIVERS 2",
            rating: .runsWell,
            antiCheat: "nProtect GameGuard",
            minimumCrossOverMajor: 26,
            recommendation: Recommendation(graphics: .d3dMetal, msync: false, advertiseAVX: true, highResolutionMode: false),
            note: "Runs in CrossOver 26 or later, including online play. GameGuard works there because of CodeWeavers' own patches; it does not get past GameGuard in Whisky, the Game Porting Toolkit or plain Wine. The game is DirectX 12 only, so it needs D3DMetal, and AVX must be advertised or it stops with \"Incompatible CPU detected\". Players report the smoothest results with MSync off. Game patches have broken it before (CrossOver 26.2 shipped a fix), so it can break again. On a base M1/M2 expect roughly 20-35 fps at low settings around 720p-1080p (base M3/M4 MacBook Airs report 30-40 fps); 16 GB of memory is recommended.",
            asOf: "2026-10"
        ),
        Entry(
            appID: "1085660",
            title: "Destiny 2",
            rating: .blocked,
            antiCheat: "BattlEye",
            minimumCrossOverMajor: nil,
            recommendation: nil,
            note: "Bungie blocks Wine and Proton. Launching it under translation fails and risks account action.",
            asOf: "2026-10"
        ),
        Entry(
            appID: "1172470",
            title: "Apex Legends",
            rating: .blocked,
            antiCheat: "Easy Anti-Cheat",
            minimumCrossOverMajor: nil,
            recommendation: nil,
            note: "EA turned off Wine/Proton support for its anti-cheat in 2024, so matchmaking is blocked.",
            asOf: "2026-10"
        ),
        Entry(
            appID: "1091500",
            title: "Cyberpunk 2077",
            rating: .native,
            antiCheat: nil,
            minimumCrossOverMajor: nil,
            recommendation: nil,
            note: "A native Apple Silicon version shipped in 2025. Install it with the macOS Steam client for much better performance than translation.",
            asOf: "2026-10"
        ),
        Entry(
            appID: "1086940",
            title: "Baldur's Gate 3",
            rating: .native,
            antiCheat: nil,
            minimumCrossOverMajor: nil,
            recommendation: nil,
            note: "Has a native macOS version. Install it with the macOS Steam client instead.",
            asOf: "2026-10"
        ),
    ]

    /// Looks up a title. A known App ID is authoritative: when one is given, only
    /// an exact App ID match counts, so sequels and similarly named games never
    /// inherit another title's verdict. The name is used only without an App ID,
    /// and then only as a whole normalized-title match.
    static func lookup(appID: String?, name: String?) -> Entry? {
        let id = appID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !id.isEmpty {
            return entries.first { $0.appID == id }
        }
        let normalized = normalize(name ?? "")
        guard !normalized.isEmpty else { return nil }
        return entries.first { normalize($0.title) == normalized }
    }

    /// What an entry means for a bottle running on `engine`.
    static func assessment(of entry: Entry, engine: WineEngine?) -> String? {
        guard let minimum = entry.minimumCrossOverMajor else { return nil }
        guard let engine else { return "Needs CrossOver \(minimum) or later; this bottle has no engine selected." }
        guard engine.kind == .crossOver else {
            return "Needs CrossOver \(minimum) or later. \(engine.name) cannot run it."
        }
        if let major = engine.majorVersion, major < minimum {
            return "Needs CrossOver \(minimum) or later; this bottle uses \(engine.name)."
        }
        return nil
    }

    /// Lowercased alphanumerics and single spaces; strips ™ and ® so
    /// "HELLDIVERS™ 2" matches "Helldivers 2".
    static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty, result.last != " " {
                result.append(" ")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
