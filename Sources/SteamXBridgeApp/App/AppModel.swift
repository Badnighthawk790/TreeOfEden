#if os(macOS)
import AppKit
import Combine
import Foundation

/// What a bottle contains, scanned off the main thread.
struct BottleContents {
    var steam: SteamInstallation?
    var steamApps: [SteamApp] = []
    var programs: [InstalledProgram] = []
}

/// A program started from the app, tracked until it exits.
struct RunRecord: Identifiable {
    let id: UUID
    let bottleID: UUID
    let name: String
    let startedAt: Date
    let logURL: URL
    let wineLogURL: URL?
    var exitStatus: Int32?

    var isRunning: Bool { exitStatus == nil }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A launch that needs the user's confirmation first (a game flagged by the
/// compatibility database).
struct LaunchRequest: Identifiable {
    let id = UUID()
    let target: LaunchTarget
    let bottleID: UUID
    let title: String
    let message: String
    /// False when launching cannot work at all (for example an engine mismatch).
    let canLaunchAnyway: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var bottles: [Bottle] = []
    @Published private(set) var detectedEngines: [WineEngine] = []
    @Published private(set) var customEngines: [WineEngine] = []
    @Published private(set) var externalBottles: [ExternalBottle] = []
    @Published private(set) var contents: [UUID: BottleContents] = [:]
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var activity: [UUID: String] = [:]
    @Published private(set) var globalActivity: String?
    @Published private(set) var isLoading = true
    @Published var selection: UUID? {
        didSet {
            UserDefaults.standard.set(selection?.uuidString, forKey: Self.selectionKey)
            if let selection, selection != oldValue { refreshContents(selection) }
        }
    }
    @Published var alert: AppAlert?
    @Published var launchRequest: LaunchRequest?
    /// Set to ask for confirmation before removing a bottle.
    @Published var bottlePendingRemoval: Bottle?
    @Published var showingNewBottle = false
    /// Set to present the "Run Command…" file picker for a bottle.
    @Published var runCommandBottleID: UUID?

    let gpu = GPUStack.detect()
    let store = BottleStore()
    let crossOverBottleDirectory: URL

    private static let selectionKey = "selectedBottle"
    private static let customEnginesKey = "customEngines"

    init() {
        crossOverBottleDirectory = EngineDiscovery().crossOverBottleDirectory()
        customEngines = Self.loadCustomEngines()
        reload()
    }

    private var operations: BottleOperations {
        BottleOperations(store: store, gpu: gpu, crossOverBottleDirectory: crossOverBottleDirectory)
    }

    // MARK: Lookups

    var engines: [WineEngine] { detectedEngines + customEngines }
    var selectedBottle: Bottle? { selection.flatMap(bottle) }

    func bottle(_ id: UUID) -> Bottle? { bottles.first { $0.id == id } }

    /// Engines that can run a bottle: CrossOver bottles need CrossOver, and
    /// CrossOver cannot reach prefixes outside its own bottle folder.
    func compatibleEngines(for bottle: Bottle) -> [WineEngine] {
        let isCrossOver = bottle.isCrossOverBottle
        return Self.ordered(engines.filter { $0.isCrossOver == isCrossOver })
    }

    func engine(for bottle: Bottle) -> WineEngine? {
        let candidates = compatibleEngines(for: bottle)
        if let id = bottle.engineID, let chosen = candidates.first(where: { $0.id == id }) { return chosen }
        return candidates.first
    }

    /// Best engines first: CrossOver, then WhiskyWine, the Game Porting Toolkit,
    /// WineHQ builds, Sikarugir, custom engines, and the CrossOver Preview last.
    static func ordered(_ engines: [WineEngine]) -> [WineEngine] {
        let rank: [EngineKind: Int] = [.crossOver: 0, .whisky: 1, .gamePortingToolkit: 2, .wineHQ: 3,
                                       .sikarugir: 4, .custom: 5, .crossOverPreview: 6]
        return engines.enumerated().sorted {
            (rank[$0.element.kind] ?? 9, $0.offset) < (rank[$1.element.kind] ?? 9, $1.offset)
        }.map(\.element)
    }

    func runs(for bottleID: UUID) -> [RunRecord] {
        runs.filter { $0.bottleID == bottleID }.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Loading

    func reload() {
        isLoading = true
        let store = self.store
        Task {
            let (loaded, engines, external) = await Task.detached(priority: .userInitiated) {
                (store.loadBottles(), EngineDiscovery().discover(), ExternalBottleFinder().discover())
            }.value
            bottles = loaded.bottles
            detectedEngines = engines
            refreshExternal(external)
            isLoading = false
            if !loaded.problems.isEmpty {
                alert = AppAlert(title: "Some bottles could not be loaded", message: loaded.problems.joined(separator: "\n"))
            }
            let saved = UserDefaults.standard.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:))
            if let saved, self.bottle(saved) != nil {
                selection = saved
            } else if selection == nil || self.bottle(selection!) == nil {
                selection = bottles.first?.id
            }
            if let selection { refreshContents(selection) }
        }
    }

    private func refreshExternal(_ found: [ExternalBottle]) {
        let linked = Set(bottles.map { $0.prefixURL.canonicalPath })
        externalBottles = found.filter { !linked.contains($0.prefix.canonicalPath) }
    }

    func rescanExternalBottles() {
        Task {
            let found = await Task.detached { ExternalBottleFinder().discover() }.value
            refreshExternal(found)
        }
    }

    func refreshContents(_ id: UUID) {
        guard let bottle = self.bottle(id) else { return }
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> BottleContents in
                var result = BottleContents()
                if let steam = SteamInstallation.locate(inPrefix: bottle.prefixURL) {
                    result.steam = steam
                    result.steamApps = SteamLibraryReader(installation: steam).installedApps()
                }
                result.programs = ProgramDiscovery(prefix: bottle.prefixURL).programs()
                return result
            }.value
            contents[id] = scanned
        }
    }

    // MARK: Running work

    /// Runs `work`, showing `title` as the bottle's (or the app's) activity and
    /// turning any error into an alert.
    private func perform(_ title: String, on bottleID: UUID?, _ work: @escaping () async throws -> Void) {
        Task {
            if let bottleID { activity[bottleID] = title } else { globalActivity = title }
            do {
                try await work()
            } catch {
                alert = AppAlert(title: "\(title) failed", message: error.localizedDescription)
            }
            if let bottleID { activity[bottleID] = nil } else { globalActivity = nil }
        }
    }

    // MARK: Bottles

    func createBottle(named name: String, engine: WineEngine, windowsVersion: WindowsVersion, installSteam: Bool) {
        let ops = operations
        let existing = bottles
        perform("Creating \(name)", on: nil) {
            let bottle = engine.isCrossOver
                ? try await ops.createCrossOverBottle(named: name, engine: engine, windowsVersion: windowsVersion,
                                                      settings: BottleSettings(), existing: existing)
                : try await ops.createPlainBottle(named: name, engine: engine, windowsVersion: windowsVersion,
                                                  settings: BottleSettings())
            self.insert(bottle)
            if installSteam { self.installSteam(in: bottle.id) }
        }
    }

    func link(_ external: ExternalBottle) {
        do {
            var bottle = try store.linkBottle(prefix: external.prefix, named: external.name, source: external.source, existing: bottles)
            bottle.engineID = preferredEngine(for: external)?.id
            try store.save(bottle)
            insert(bottle)
            externalBottles.removeAll { $0.id == external.id }
        } catch {
            alert = AppAlert(title: "Could not add \(external.name)", message: error.localizedDescription)
        }
    }

    func linkFolder(_ url: URL) {
        let source = FileManager.default.fileExists(atPath: url.appendingPathComponent("cxbottle.conf").path)
            ? ExternalBottleFinder.crossOverSource : "Wine prefix"
        link(ExternalBottle(name: url.lastPathComponent, prefix: url, source: source,
                            hasSteam: SteamInstallation.locate(inPrefix: url) != nil))
    }

    private func preferredEngine(for external: ExternalBottle) -> WineEngine? {
        let ordered = Self.ordered(engines)
        switch external.source {
        case ExternalBottleFinder.crossOverSource:
            return ordered.first(where: \.isCrossOver)
        case "Whisky":
            return ordered.first { $0.kind == .whisky } ?? ordered.first { !$0.isCrossOver }
        case "Sikarugir":
            return ordered.first { $0.kind == .sikarugir && $0.bundlePath.map { external.prefix.path.hasPrefix($0) } == true }
                ?? ordered.first { !$0.isCrossOver }
        default:
            return ordered.first { !$0.isCrossOver }
        }
    }

    private func insert(_ bottle: Bottle) {
        bottles.removeAll { $0.id == bottle.id }
        bottles.append(bottle)
        bottles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = bottle.id
        refreshContents(bottle.id)
    }

    /// Saves edited settings, then applies the parts that live outside the
    /// launch environment (cxbottle.conf, registry, Windows version, DXVK files).
    func save(_ updated: Bottle) {
        guard let old = bottle(updated.id) else { return }
        do {
            try store.save(updated)
        } catch {
            alert = AppAlert(title: "Could not save \(updated.name)", message: error.localizedDescription)
            return
        }
        if let index = bottles.firstIndex(where: { $0.id == updated.id }) { bottles[index] = updated }
        guard let engine = self.engine(for: updated) else { return }
        let ops = operations
        perform("Applying settings", on: updated.id) {
            try await ops.applySettings(from: old, to: updated, engine: engine)
        }
    }

    func applyRecommendation(_ entry: GameCompatibility.Entry, to bottle: Bottle) {
        guard let recommendation = entry.recommendation else { return }
        var updated = bottle
        recommendation.apply(to: &updated.settings)
        save(updated)
    }

    func duplicate(_ bottle: Bottle) {
        let ops = operations
        let store = self.store
        let existing = bottles
        let bottleEngine = self.engine(for: bottle)
        perform("Duplicating \(bottle.name)", on: bottle.id) {
            let copy: Bottle
            if bottle.isCrossOverBottle, let bottleEngine {
                copy = try await ops.duplicateCrossOverBottle(bottle, named: "\(bottle.name) copy", engine: bottleEngine, existing: existing)
            } else {
                copy = try await Task.detached(priority: .userInitiated) {
                    try store.duplicate(bottle, named: "\(bottle.name) copy")
                }.value
            }
            self.insert(copy)
        }
    }

    func remove(_ bottle: Bottle) {
        do {
            try store.remove(bottle)
            bottles.removeAll { $0.id == bottle.id }
            contents[bottle.id] = nil
            selection = bottles.first?.id
            rescanExternalBottles()
        } catch {
            alert = AppAlert(title: "Could not remove \(bottle.name)", message: error.localizedDescription)
        }
    }

    // MARK: Programs

    func pin(_ url: URL, in bottle: Bottle) {
        var updated = bottle
        guard !updated.pinnedPrograms.contains(where: { $0.path == url.path }) else { return }
        updated.pinnedPrograms.append(PinnedProgram(name: url.deletingPathExtension().lastPathComponent, path: url.path))
        persist(updated)
    }

    func unpin(_ program: PinnedProgram, in bottle: Bottle) {
        var updated = bottle
        updated.pinnedPrograms.removeAll { $0.id == program.id }
        persist(updated)
    }

    /// Saves metadata-only changes (pins, names) without re-applying settings.
    func persist(_ updated: Bottle) {
        do {
            try store.save(updated)
            if let index = bottles.firstIndex(where: { $0.id == updated.id }) { bottles[index] = updated }
        } catch {
            alert = AppAlert(title: "Could not save \(updated.name)", message: error.localizedDescription)
        }
    }

    // MARK: Launching

    /// Launches a target. Steam games flagged by the compatibility database ask
    /// for confirmation first (or explain why they cannot run on this engine).
    func launch(_ target: LaunchTarget, in bottle: Bottle, confirmed: Bool = false) {
        guard let engine = self.engine(for: bottle) else {
            alert = AppAlert(title: "No engine for \(bottle.name)",
                             message: bottle.isCrossOverBottle
                                ? "This is a CrossOver bottle. Install CrossOver to run it."
                                : "Install a Wine engine (CrossOver, the Game Porting Toolkit, or Wine) and check Settings > Engines.")
            return
        }
        if !confirmed, case .steamGame(let appID, _) = target, let entry = GameCompatibility.lookup(appID: appID, name: nil) {
            if let problem = GameCompatibility.assessment(of: entry, engine: engine) {
                launchRequest = LaunchRequest(target: target, bottleID: bottle.id, title: "\(entry.title) needs CrossOver",
                                              message: "\(problem)\n\n\(entry.note)", canLaunchAnyway: false)
                return
            }
            switch entry.rating {
            case .blocked:
                launchRequest = LaunchRequest(target: target, bottleID: bottle.id, title: "\(entry.title) does not run on a Mac",
                                              message: entry.note, canLaunchAnyway: true)
                return
            case .native:
                launchRequest = LaunchRequest(target: target, bottleID: bottle.id, title: "\(entry.title) has a native Mac version",
                                              message: entry.note, canLaunchAnyway: true)
                return
            case .runsWell, .playable:
                break
            }
        }

        let runID = UUID()
        do {
            let running = try operations.launch(target, in: bottle, engine: engine, runID: runID) { [weak self] status in
                Task { @MainActor in self?.finishRun(runID, status: status) }
            }
            runs.append(RunRecord(id: runID, bottleID: bottle.id, name: running.name, startedAt: running.startedAt,
                                  logURL: running.logURL, wineLogURL: running.wineLogURL))
        } catch {
            alert = AppAlert(title: "Could not start \(target.displayName)", message: error.localizedDescription)
        }
    }

    func confirmLaunch(_ request: LaunchRequest) {
        launchRequest = nil
        guard request.canLaunchAnyway, let bottle = self.bottle(request.bottleID) else { return }
        launch(request.target, in: bottle, confirmed: true)
    }

    private func finishRun(_ id: UUID, status: Int32) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].exitStatus = status
        let run = runs[index]
        // A quick non-zero exit usually means the program never started; point at the log.
        if status != 0, Date().timeIntervalSince(run.startedAt) < 15 {
            alert = AppAlert(title: "\(run.name) exited with status \(status)",
                             message: "It stopped right after starting. The log may say why:\n\(run.logURL.path)")
        }
        if let bottleID = runs.first(where: { $0.id == id })?.bottleID { refreshContents(bottleID) }
    }

    func forceQuit(_ bottle: Bottle) {
        guard let engine = self.engine(for: bottle) else { return }
        let ops = operations
        perform("Force quitting", on: bottle.id) { try await ops.forceQuit(bottle, engine: engine) }
    }

    func simulateReboot(_ bottle: Bottle) {
        guard let engine = self.engine(for: bottle) else { return }
        let ops = operations
        perform("Simulating reboot", on: bottle.id) { try await ops.simulateReboot(bottle, engine: engine) }
    }

    func installSteam(in bottleID: UUID) {
        guard let bottle = self.bottle(bottleID), let engine = self.engine(for: bottle) else { return }
        let ops = operations
        perform("Installing Steam", on: bottleID) {
            let steam = try await ops.installSteam(in: bottle, engine: engine)
            self.refreshContents(bottleID)
            // Steam updates itself on its first run, as CrossOver's Steam install does.
            self.launch(.steamClient(steam), in: bottle)
        }
    }

    // MARK: Engines

    func addCustomEngine(at url: URL) {
        guard let engine = EngineDiscovery.customEngine(at: url) else {
            alert = AppAlert(title: "Not a Wine engine",
                             message: "Choose an executable named \"wine\" or \"wine64\" (for CrossOver, its SharedSupport/CrossOver/bin/wine).")
            return
        }
        guard !engines.contains(where: { $0.id == engine.id }) else { return }
        customEngines.append(engine)
        saveCustomEngines()
    }

    func removeCustomEngine(_ engine: WineEngine) {
        customEngines.removeAll { $0.id == engine.id }
        saveCustomEngines()
    }

    private func saveCustomEngines() {
        if let data = try? JSONEncoder().encode(customEngines) {
            UserDefaults.standard.set(data, forKey: Self.customEnginesKey)
        }
    }

    private static func loadCustomEngines() -> [WineEngine] {
        guard let data = UserDefaults.standard.data(forKey: customEnginesKey),
              let engines = try? JSONDecoder().decode([WineEngine].self, from: data) else { return [] }
        return engines.filter { FileManager.default.fileExists(atPath: $0.loaderPath) }
    }

    // MARK: Finder

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
