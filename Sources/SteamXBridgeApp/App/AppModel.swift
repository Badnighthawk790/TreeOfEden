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
    /// A Steam game launch: steam.exe hands the game to the running client and
    /// exits, so its exit says nothing about the game itself.
    var launchedThroughSteam = false
    /// Set when the user force-quit the bottle, so the exit is not reported as a crash.
    var stopRequested = false

    var isRunning: Bool { exitStatus == nil }

    var statusText: String {
        guard let exitStatus else { return "Running" }
        if launchedThroughSteam, exitStatus == 0 { return "Started through Steam" }
        if stopRequested { return "Stopped" }
        return "Exited with status \(exitStatus)"
    }
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

/// Settings that can only be applied with the bottle's programs closed.
struct PendingApply: Identifiable {
    let id = UUID()
    let old: Bottle
    let updated: Bottle
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
    /// Set to ask whether to quit a bottle's programs before applying settings.
    @Published var pendingApply: PendingApply?
    /// Unapplied edits from the Settings tab, kept per bottle so switching tabs
    /// or bottles never drops them.
    @Published var settingsDrafts: [UUID: Bottle] = [:]
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

    /// True while an operation runs in the bottle or one of its programs is open.
    func isBusy(_ bottle: Bottle) -> Bool {
        activity[bottle.id] != nil || runs(for: bottle.id).contains(where: \.isRunning)
    }

    /// Everything that would be interrupted by quitting the app.
    var workInProgress: [String] {
        var items = activity.compactMap { id, title in bottle(id).map { "\(title) in \($0.name)" } }
        if let globalActivity { items.append(globalActivity) }
        return items.sorted()
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
            if self.bottle(id) != nil { contents[id] = scanned }
        }
    }

    // MARK: Running work

    /// Runs `work`, showing `title` as the bottle's (or the app's) activity and
    /// turning any error into an alert. Exclusive work refuses to start while
    /// another operation runs in the same bottle; the check and the claim happen
    /// synchronously, so two clicks can never both start.
    @discardableResult
    private func perform(_ title: String, on bottleID: UUID?, exclusive: Bool = true,
                         _ work: @escaping () async throws -> Void) -> Bool {
        if let bottleID {
            if exclusive {
                if let current = activity[bottleID] {
                    alert = AppAlert(title: "\(title) can wait", message: "\(current) is still running in this bottle.")
                    return false
                }
                activity[bottleID] = title
            }
        } else {
            if let current = globalActivity {
                alert = AppAlert(title: "\(title) can wait", message: "\(current) is still running.")
                return false
            }
            globalActivity = title
        }
        Task {
            do {
                try await work()
            } catch {
                alert = AppAlert(title: "\(title) failed", message: error.localizedDescription)
            }
            if let bottleID {
                if exclusive { activity[bottleID] = nil }
            } else {
                globalActivity = nil
            }
        }
        return true
    }

    /// The bottle's engine, or an explanatory alert when there is none.
    private func requireEngine(for bottle: Bottle) -> WineEngine? {
        if let engine = engine(for: bottle) { return engine }
        alert = AppAlert(title: "No engine for \(bottle.name)",
                         message: bottle.isCrossOverBottle
                            ? "This is a CrossOver bottle. Install CrossOver to run it."
                            : "Install a Wine engine (CrossOver, the Game Porting Toolkit, or Wine) and check Settings > Engines.")
        return nil
    }

    // MARK: Bottles

    func createBottle(named name: String, engine: WineEngine, windowsVersion: WindowsVersion, installSteam: Bool) {
        let ops = operations
        let existing = bottles
        // Steam's client needs Windows 10 or later.
        let wantsSteam = installSteam && (windowsVersion == .win10 || windowsVersion == .win11)
        perform("Creating \(name)", on: nil) {
            let bottle = engine.isCrossOver
                ? try await ops.createCrossOverBottle(named: name, engine: engine, windowsVersion: windowsVersion,
                                                      settings: BottleSettings(), existing: existing)
                : try await ops.createPlainBottle(named: name, engine: engine, windowsVersion: windowsVersion,
                                                  settings: BottleSettings())
            self.insert(bottle)
            if wantsSteam { self.installSteam(in: bottle.id) }
        }
    }

    /// True when a CrossOver bottle of that name already exists (the name is its folder).
    func crossOverBottleExists(named name: String) -> Bool {
        guard let folder = try? BottleOperations.crossOverBottleName(name) else { return false }
        return FileManager.default.fileExists(atPath: crossOverBottleDirectory.appendingPathComponent(folder).path)
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
        let isCrossOver = FileManager.default.fileExists(atPath: url.appendingPathComponent("cxbottle.conf").path)
        // CrossOver can only run bottles in its own folder; refuse one elsewhere
        // instead of adding a bottle nothing can run.
        if isCrossOver, url.deletingLastPathComponent().canonicalPath != crossOverBottleDirectory.canonicalPath {
            alert = AppAlert(title: "Not in CrossOver's Bottles folder",
                             message: LaunchPlanError.crossOverBottleOutsideLibrary(crossOverBottleDirectory.path).errorDescription ?? "")
            return
        }
        link(ExternalBottle(name: url.lastPathComponent, prefix: url,
                            source: isCrossOver ? ExternalBottleFinder.crossOverSource : "Wine prefix",
                            hasSteam: SteamInstallation.locate(inPrefix: url) != nil))
    }

    private func preferredEngine(for external: ExternalBottle) -> WineEngine? {
        let ordered = Self.ordered(engines)
        let anyPlain = ordered.first { !$0.isCrossOver }
        switch external.source {
        case ExternalBottleFinder.crossOverSource:
            return ordered.first(where: \.isCrossOver)
        case "Whisky":
            // The bottle's own Whisky (original or community fork) first.
            if let hint = external.engineHint,
               let own = ordered.first(where: { $0.kind == .whisky && $0.loaderPath.contains("/\(hint)/") }) {
                return own
            }
            return ordered.first { $0.kind == .whisky } ?? anyPlain
        case "Sikarugir":
            return ordered.first { $0.kind == .sikarugir && $0.bundlePath.map { external.prefix.path.hasPrefix($0) } == true }
                ?? anyPlain
        default:
            if external.engineHint == "gptk", let gptk = ordered.first(where: { $0.kind == .gamePortingToolkit }) {
                return gptk
            }
            return anyPlain
        }
    }

    private func insert(_ bottle: Bottle) {
        bottles.removeAll { $0.id == bottle.id }
        bottles.append(bottle)
        bottles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = bottle.id
        refreshContents(bottle.id)
    }

    /// Saves edited settings and applies them. Changes that need the bottle's
    /// wineserver stopped (CrossOver's cxbottle.conf, sync mode, engine) ask
    /// first when programs are running in it. Edits that are not applied, for
    /// whatever reason, stay in the Settings draft.
    func save(_ updated: Bottle) {
        guard let old = bottle(updated.id), !deferIfBusy(updated) else { return }
        let settingsChanged = old.settings != updated.settings || old.windowsVersion != updated.windowsVersion
            || old.engineID != updated.engineID
        guard settingsChanged else {
            if persist(updated) { clearDraft(ifMatching: updated) } // a rename: nothing to apply
            return
        }
        let running = runs(for: updated.id).contains(where: \.isRunning)
        let needsStop = updated.isCrossOverBottle || old.settings.msync != updated.settings.msync
            || old.settings.esync != updated.settings.esync || old.engineID != updated.engineID
        if running, needsStop {
            keepUnapplied(updated)
            pendingApply = PendingApply(old: old, updated: updated)
            return
        }
        apply(old: old, updated: updated, quitFirst: false)
    }

    /// "Quit Programs and Apply": takes the alert's own value, since SwiftUI
    /// clears `pendingApply` when the alert closes.
    func confirmPendingApply(_ pending: PendingApply) {
        pendingApply = nil
        // Apply onto the bottle as it is now, keeping anything changed while the
        // question was open (a pin).
        guard let current = bottle(pending.updated.id) else { return }
        apply(old: current, updated: Self.withSettings(of: pending.updated, on: current), quitFirst: true)
    }

    private func apply(old: Bottle, updated: Bottle, quitFirst: Bool) {
        guard !deferIfBusy(updated) else { return }
        guard let engine = self.engine(for: updated) else {
            // Nothing would apply them later, so they are not saved as applied.
            keepUnapplied(updated)
            alert = AppAlert(title: "No engine to apply these settings",
                             message: (updated.isCrossOverBottle ? "Install CrossOver" : "Install a Wine engine")
                                + " to apply them. Your changes stay in the Settings tab until then.")
            return
        }
        guard persist(updated) else { keepUnapplied(updated); return }
        clearDraft(ifMatching: updated)
        if quitFirst { markStopRequested(updated.id) }
        let ops = operations
        // Cannot be refused: the bottle was checked idle above, synchronously.
        perform("Applying settings", on: updated.id) {
            do {
                if quitFirst { try await ops.forceQuit(updated, engine: engine) }
                try await ops.applySettings(from: old, to: updated, engine: engine)
            } catch {
                self.rollBack(updated, to: old)
                throw error
            }
        }
    }

    /// Refuses to change settings while an operation runs in the bottle; the
    /// edits stay in the Settings draft.
    private func deferIfBusy(_ updated: Bottle) -> Bool {
        guard let current = activity[updated.id] else { return false }
        keepUnapplied(updated)
        alert = AppAlert(title: "Settings can wait",
                         message: "\(current) is still running in this bottle. Your changes stay in the Settings tab until you apply them.")
        return true
    }

    /// Records a failed apply as unapplied, so Apply can retry it. Only the
    /// settings go back (the name and pins are kept), and only if nothing else
    /// changed them meanwhile. applySettings has already restored cxbottle.conf.
    private func rollBack(_ updated: Bottle, to old: Bottle) {
        guard let current = bottle(updated.id), Self.sameSettings(current, updated) else { return }
        var restored = Self.withSettings(of: old, on: current)
        restored.name = current.name
        persist(restored)
        keepUnapplied(updated)
    }

    /// Keeps edits that were not applied in the Settings draft. A draft that is
    /// already open holds them (and possibly more), so it is left alone.
    private func keepUnapplied(_ updated: Bottle) {
        if settingsDrafts[updated.id] == nil { settingsDrafts[updated.id] = updated }
    }

    /// True when two versions of a bottle agree on everything the Settings tab edits.
    static func sameSettings(_ a: Bottle, _ b: Bottle) -> Bool {
        a.name == b.name && a.engineID == b.engineID && a.windowsVersion == b.windowsVersion && a.settings == b.settings
    }

    /// `base` with the fields the Settings tab edits taken from `source`.
    static func withSettings(of source: Bottle, on base: Bottle) -> Bottle {
        var result = base
        result.name = source.name
        result.engineID = source.engineID
        result.windowsVersion = source.windowsVersion
        result.settings = source.settings
        return result
    }

    /// Drops the Settings draft once what was saved matches it (other pending
    /// edits in the draft survive).
    private func clearDraft(ifMatching saved: Bottle) {
        if let draft = settingsDrafts[saved.id], Self.sameSettings(draft, saved) { settingsDrafts[saved.id] = nil }
    }

    /// Applies a compatibility entry's recommended settings, but only on an
    /// engine that can run the title, and only renderers that engine offers.
    func applyRecommendation(_ entry: GameCompatibility.Entry, to bottle: Bottle) {
        guard let recommendation = entry.recommendation, let bottle = self.bottle(bottle.id) else { return }
        let engine = engine(for: bottle)
        if let problem = GameCompatibility.assessment(of: entry, engine: engine) {
            alert = AppAlert(title: "\(entry.title) cannot run in \(bottle.name)", message: problem)
            return
        }
        func recommended(_ base: Bottle) -> Bottle {
            var result = base
            recommendation.apply(to: &result.settings)
            if let engine, !engine.graphicsBackends.contains(result.settings.graphics) {
                result.settings.graphics = base.settings.graphics
            }
            return result
        }
        // Put it in the Settings draft as well: an open draft stays consistent,
        // so a later Apply does not undo it, and a deferred apply is not lost.
        settingsDrafts[bottle.id] = recommended(settingsDrafts[bottle.id] ?? bottle)
        save(recommended(bottle))
    }

    func duplicate(_ bottle: Bottle) {
        guard !isBusy(bottle) else {
            alert = AppAlert(title: "\(bottle.name) is in use",
                             message: "Quit its programs (Force Quit) and wait for the current operation to finish first.")
            return
        }
        let bottleEngine = self.engine(for: bottle)
        if bottle.isCrossOverBottle, bottleEngine == nil {
            alert = AppAlert(title: "Install CrossOver to duplicate \(bottle.name)",
                             message: "CrossOver bottles are copied with CrossOver's own tool, so CrossOver can still run the copy.")
            return
        }
        let ops = operations
        let store = self.store
        let existing = bottles
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
        guard !isBusy(bottle) else {
            alert = AppAlert(title: "\(bottle.name) is in use",
                             message: "Quit its programs (Force Quit) and wait for the current operation to finish first.")
            return
        }
        do {
            try store.remove(bottle)
            bottles.removeAll { $0.id == bottle.id }
            contents[bottle.id] = nil
            settingsDrafts[bottle.id] = nil
            if selection == bottle.id { selection = bottles.first?.id }
            rescanExternalBottles()
        } catch {
            alert = AppAlert(title: "Could not remove \(bottle.name)", message: error.localizedDescription)
        }
    }

    // MARK: Programs

    func pin(_ url: URL, arguments: [String] = [], in bottle: Bottle) {
        var updated = bottle
        guard !updated.pinnedPrograms.contains(where: { $0.path == url.path }) else { return }
        updated.pinnedPrograms.append(PinnedProgram(name: url.deletingPathExtension().lastPathComponent,
                                                    path: url.path, arguments: arguments))
        persist(updated)
    }

    func unpin(_ program: PinnedProgram, in bottle: Bottle) {
        var updated = bottle
        updated.pinnedPrograms.removeAll { $0.id == program.id }
        persist(updated)
    }

    /// Saves metadata-only changes (pins, names) without re-applying settings.
    @discardableResult
    func persist(_ updated: Bottle) -> Bool {
        do {
            try store.save(updated)
            if let index = bottles.firstIndex(where: { $0.id == updated.id }) { bottles[index] = updated }
            return true
        } catch {
            alert = AppAlert(title: "Could not save \(updated.name)", message: error.localizedDescription)
            return false
        }
    }

    // MARK: Launching

    /// Launches a target. Steam games flagged by the compatibility database ask
    /// for confirmation first (or explain why they cannot run on this engine).
    /// `duringOperation` lets an operation start a program in its own bottle
    /// (Install Steam's first run of Steam).
    func launch(_ target: LaunchTarget, in bottle: Bottle, confirmed: Bool = false, waitForChildren: Bool = false,
                duringOperation: Bool = false) {
        // Duplicating copies the prefix and applying settings changes it under
        // the wineserver, so nothing starts while an operation runs.
        if !duringOperation, let current = activity[bottle.id] {
            alert = AppAlert(title: "\(bottle.name) is busy",
                             message: "\(current) is still running. Start \(target.displayName) once it has finished.")
            return
        }
        guard let engine = requireEngine(for: bottle) else { return }
        if !confirmed, case .steamGame(let appID, _) = target, let entry = GameCompatibility.lookup(appID: appID, name: nil) {
            if let problem = GameCompatibility.assessment(of: entry, engine: engine) {
                launchRequest = LaunchRequest(target: target, bottleID: bottle.id, title: "\(entry.title) needs CrossOver",
                                              message: "\(problem)\n\n\(entry.note)", canLaunchAnyway: false)
                return
            }
            if let advice = GameCompatibility.advisory(of: entry, engine: engine) {
                launchRequest = LaunchRequest(target: target, bottleID: bottle.id, title: "Update CrossOver for \(entry.title)",
                                              message: advice, canLaunchAnyway: true)
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
            let running = try operations.launch(target, in: bottle, engine: engine, runID: runID,
                                                waitForChildren: waitForChildren) { [weak self] status in
                Task { @MainActor in self?.finishRun(runID, status: status) }
            }
            var record = RunRecord(id: runID, bottleID: bottle.id, name: running.name, startedAt: running.startedAt,
                                   logURL: running.logURL, wineLogURL: running.wineLogURL)
            if case .steamGame = target { record.launchedThroughSteam = true }
            runs.append(record)
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
        // A quick non-zero exit usually means the program never started; point at
        // the log. Not when the user stopped it, and not for Steam's hand-off.
        if status != 0, !run.stopRequested, !run.launchedThroughSteam, Date().timeIntervalSince(run.startedAt) < 15 {
            alert = AppAlert(title: "\(run.name) exited with status \(status)",
                             message: "It stopped right after starting. The log may say why:\n\(run.logURL.path)")
        }
        refreshContents(run.bottleID)
    }

    private func markStopRequested(_ bottleID: UUID) {
        for index in runs.indices where runs[index].bottleID == bottleID && runs[index].isRunning {
            runs[index].stopRequested = true
        }
    }

    func forceQuit(_ bottle: Bottle) {
        guard let engine = requireEngine(for: bottle) else { return }
        let ops = operations
        markStopRequested(bottle.id)
        // Not exclusive: Force Quit must work even while another operation hangs.
        perform("Force quitting", on: bottle.id, exclusive: false) { try await ops.forceQuit(bottle, engine: engine) }
    }

    func simulateReboot(_ bottle: Bottle) {
        guard let engine = requireEngine(for: bottle) else { return }
        let ops = operations
        perform("Simulating reboot", on: bottle.id) { try await ops.simulateReboot(bottle, engine: engine) }
    }

    func installSteam(in bottleID: UUID) {
        guard let bottle = self.bottle(bottleID), let engine = requireEngine(for: bottle) else { return }
        guard bottle.windowsVersion == .win10 || bottle.windowsVersion == .win11 else {
            alert = AppAlert(title: "Steam needs Windows 10 or later",
                             message: "Set this bottle's Windows version to Windows 10 or 11 in Settings, or create a new bottle for Steam.")
            return
        }
        let ops = operations
        perform("Installing Steam", on: bottleID) {
            let steam = try await ops.installSteam(in: bottle, engine: engine)
            self.refreshContents(bottleID)
            // Steam updates itself on its first run, as CrossOver's Steam install does.
            guard let current = self.bottle(bottleID) else { return } // removed meanwhile
            self.launch(.steamClient(steam), in: current, duringOperation: true)
        }
    }

    // MARK: Engines

    /// Adds a custom engine; returns an error message for the Settings window.
    func addCustomEngine(at url: URL) -> String? {
        guard let engine = EngineDiscovery.customEngine(at: url) else {
            return "Choose an engine app (CrossOver, Wine Stable, Game Porting Toolkit) or an executable named \"wine\" or \"wine64\"."
        }
        guard !engines.contains(where: { $0.id == engine.id }) else { return "\(engine.name) is already listed." }
        customEngines.append(engine)
        saveCustomEngines()
        return nil
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
