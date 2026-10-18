import Foundation

enum BottleStoreError: LocalizedError, Equatable {
    case invalidName
    case notAWinePrefix(String)
    case alreadyLinked(String)
    case crossOverBottleNeedsCrossOver

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Bottle names must contain at least one visible character."
        case .notAWinePrefix(let path):
            return "\(path) does not look like a Wine prefix (no drive_c folder or system.reg)."
        case .alreadyLinked(let name):
            return "That prefix is already in SteamXBridge as \"\(name)\"."
        case .crossOverBottleNeedsCrossOver:
            return "CrossOver bottles are duplicated with CrossOver's own tool. Install CrossOver to duplicate this bottle."
        }
    }
}

/// Persists bottles on disk:
///
///     <root>/Bottles/<uuid>.json      metadata for every bottle
///     <root>/Prefixes/<slug>-<id8>/   prefixes of bottles SteamXBridge created
///     <root>/Logs/<uuid>/...          per-run logs
///     <root>/Downloads/               cached installers (SteamSetup.exe)
///
/// Prefix folders are named from a sanitized slug plus a UUID fragment, never
/// from the raw bottle name, so names cannot traverse or collide, and renaming
/// a bottle never orphans its prefix.
struct BottleStore {
    let root: URL
    /// Whether removing an owned bottle moves its prefix to the Trash (the app)
    /// or deletes it outright (tests, and platforms without a Trash).
    let deletesToTrash: Bool

    init(root: URL = BottleStore.defaultRoot(), deletesToTrash: Bool = true) {
        self.root = root
        self.deletesToTrash = deletesToTrash
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SteamXBridge", isDirectory: true)
    }

    var bottlesDirectory: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    var prefixesDirectory: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    var downloadsDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

    // MARK: Loading and saving

    /// Loads every bottle. Unreadable metadata files are reported, not fatal.
    func loadBottles() -> (bottles: [Bottle], problems: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bottlesDirectory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var bottles: [Bottle] = []
        var problems: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            do {
                bottles.append(try decoder.decode(Bottle.self, from: Data(contentsOf: file)))
            } catch {
                problems.append("Skipped \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        bottles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (bottles, problems)
    }

    func save(_ bottle: Bottle) throws {
        try FileManager.default.createDirectory(at: bottlesDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: metadataURL(for: bottle.id), options: .atomic)
    }

    func metadataURL(for id: UUID) -> URL {
        bottlesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Creating, linking, duplicating, removing

    /// Creates the metadata and an empty prefix folder for a new bottle. The
    /// prefix is initialized by running `wineboot` afterwards.
    func createBottle(named rawName: String, configure: (inout Bottle) -> Void = { _ in }) throws -> Bottle {
        let name = try Self.validatedName(rawName)
        let id = UUID()
        let folder = prefixesDirectory.appendingPathComponent(Self.folderName(for: name, id: id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var bottle = Bottle(name: name, prefixPath: folder.path, origin: .owned)
        bottle.id = id
        configure(&bottle)
        do {
            try save(bottle)
        } catch {
            try? FileManager.default.removeItem(at: folder) // never leave an orphaned prefix
            throw error
        }
        return bottle
    }

    /// Adds an existing prefix (from CrossOver, Whisky, the Game Porting Toolkit
    /// or anywhere else) without moving or modifying it.
    func linkBottle(prefix: URL, named rawName: String, source: String?, existing: [Bottle]) throws -> Bottle {
        let name = try Self.validatedName(rawName)
        guard Self.looksLikePrefix(prefix) else { throw BottleStoreError.notAWinePrefix(prefix.path) }
        let standardized = prefix.standardizedFileURL.path
        let canonical = prefix.canonicalPath
        if let twin = existing.first(where: { $0.prefixURL.canonicalPath == canonical }) {
            throw BottleStoreError.alreadyLinked(twin.name)
        }
        var bottle = Bottle(name: name, prefixPath: standardized, origin: .linked)
        bottle.linkedSource = source
        // A CrossOver bottle already has settings; start from them, not defaults.
        if let config = CrossOverBottleConfig(contentsOf: prefix.appendingPathComponent("cxbottle.conf")) {
            bottle.settings = BottleSettings(crossOverConfig: config)
        }
        try save(bottle)
        return bottle
    }

    /// Copies a bottle's prefix into a new SteamXBridge-owned bottle. Prefixes
    /// with installed games can be many gigabytes; call this off the main thread.
    func duplicate(_ source: Bottle, named rawName: String) throws -> Bottle {
        // A plain copy of a CrossOver bottle would sit outside CrossOver's bottle
        // folder, where neither CrossOver nor another engine may run it; CrossOver
        // bottles are duplicated with cxbottle instead (BottleOperations).
        guard !source.isCrossOverBottle else { throw BottleStoreError.crossOverBottleNeedsCrossOver }
        let name = try Self.validatedName(rawName)
        let id = UUID()
        try FileManager.default.createDirectory(at: prefixesDirectory, withIntermediateDirectories: true)
        let folder = prefixesDirectory.appendingPathComponent(Self.folderName(for: name, id: id), isDirectory: true)
        var copy = source
        copy.id = id
        copy.name = name
        copy.prefixPath = folder.path
        copy.origin = .owned
        copy.linkedSource = nil
        copy.createdAt = Date()
        copy.pinnedPrograms = Self.rebasedPins(source.pinnedPrograms, from: source.prefixURL, to: folder)
        do {
            try FileManager.default.copyItem(at: source.prefixURL, to: folder)
            try save(copy)
        } catch {
            try? FileManager.default.removeItem(at: folder) // a partial copy is useless and large
            throw error
        }
        return copy
    }

    /// Pins pointing inside `oldPrefix` are moved to the same place in
    /// `newPrefix`; pins elsewhere keep their path. Every pin gets a new ID.
    static func rebasedPins(_ pins: [PinnedProgram], from oldPrefix: URL, to newPrefix: URL) -> [PinnedProgram] {
        let old = oldPrefix.standardizedFileURL.path
        let new = newPrefix.standardizedFileURL.path
        return pins.map { pin in
            var rebased = pin
            rebased.id = UUID()
            let path = URL(fileURLWithPath: pin.path).standardizedFileURL.path
            if path.hasPrefix(old + "/") {
                rebased.path = new + String(path.dropFirst(old.count))
            }
            return rebased
        }
    }

    /// Removes a bottle from SteamXBridge. Owned prefixes go to the Trash (so a
    /// mistake is recoverable); linked prefixes are never touched.
    func remove(_ bottle: Bottle) throws {
        let fm = FileManager.default
        if bottle.origin == .owned, fm.fileExists(atPath: bottle.prefixPath), isOwnedPrefixSafeToDelete(bottle.prefixURL) {
            #if os(macOS)
            if deletesToTrash {
                try fm.trashItem(at: bottle.prefixURL, resultingItemURL: nil)
            } else {
                try fm.removeItem(at: bottle.prefixURL)
            }
            #else
            try fm.removeItem(at: bottle.prefixURL)
            #endif
        }
        let metadata = metadataURL(for: bottle.id)
        if fm.fileExists(atPath: metadata.path) {
            try fm.removeItem(at: metadata)
        }
    }

    /// Only a real (non-symlink) folder directly inside Prefixes, that still
    /// resolves inside the real Prefixes folder, is ever deleted: never the
    /// Prefixes folder itself, and never something a tampered path points at.
    func isOwnedPrefixSafeToDelete(_ prefix: URL) -> Bool {
        let fm = FileManager.default
        let standardized = prefix.standardizedFileURL
        let type = (try? fm.attributesOfItem(atPath: standardized.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { return false }
        guard standardized.deletingLastPathComponent().path == prefixesDirectory.standardizedFileURL.path else { return false }
        return URL(fileURLWithPath: standardized.canonicalPath).deletingLastPathComponent().path
            == prefixesDirectory.canonicalPath
    }

    // MARK: Logs

    func logURL(for bottle: Bottle, program: String, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let stamp = formatter.string(from: date)
        return logsDirectory
            .appendingPathComponent(bottle.id.uuidString, isDirectory: true)
            // A short random suffix keeps two runs in the same second apart.
            .appendingPathComponent("\(stamp)-\(Self.slug(program))-\(UUID().uuidString.prefix(4).lowercased()).log")
    }

    /// A readable title for a run log: "2026-10-18T14-03-22-steam-1a2b.log"
    /// becomes "steam · 2026-10-18 14:03:22" (CrossOver's Wine logs, named
    /// "….wine.log", get a "(Wine)" marker).
    static func logTitle(for url: URL) -> String {
        let isWineLog = url.deletingPathExtension().pathExtension == "wine"
        let name = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 7, let t = parts[2].firstIndex(of: "T") else { return name }
        let day = parts[2][..<t]
        let hour = parts[2][parts[2].index(after: t)...]
        let program = parts[5..<(parts.count - 1)].joined(separator: "-")
        return "\(program)\(isWineLog ? " (Wine)" : "") · \(parts[0])-\(parts[1])-\(day) \(hour):\(parts[3]):\(parts[4])"
    }

    /// Recent run logs for a bottle, newest first.
    func logs(for bottle: Bottle, limit: Int = 50) -> [URL] {
        let folder = logsDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Array(files.filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit))
    }

    // MARK: Helpers

    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !($0.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) }
        guard !name.isEmpty else { throw BottleStoreError.invalidName }
        return String(name.prefix(100))
    }

    /// A filesystem-safe, lowercase ASCII slug ("Steam Games!" -> "steam-games").
    static func slug(_ text: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in text.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "bottle" : String(result.prefix(40))
    }

    static func folderName(for name: String, id: UUID) -> String {
        "\(slug(name))-\(id.uuidString.prefix(8).lowercased())"
    }

    /// True when a folder already holds an initialized (or partially created) prefix.
    static func looksLikePrefix(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("drive_c").path)
            || fm.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }
}
