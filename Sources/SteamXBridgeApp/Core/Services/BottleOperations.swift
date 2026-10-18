import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BottleOperationError: LocalizedError, Equatable {
    case initializationFailed(log: String)
    case crossOverToolMissing(String)
    case crossOverBottleExists(String)
    case commandFailed(String, status: Int32, log: String?)
    case steamInstallFailed(log: String?)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let log):
            return "Wine could not initialize the bottle. Details are in \(log)."
        case .crossOverToolMissing(let path):
            return "CrossOver's bottle tool was not found at \(path)."
        case .crossOverBottleExists(let name):
            return "CrossOver already has a bottle named \"\(name)\"."
        case .commandFailed(let name, let status, let log):
            return "\(name) failed with status \(status)." + (log.map { " Details are in \($0)." } ?? "")
        case .steamInstallFailed(let log):
            return "The Steam installer finished, but steam.exe was not found in the bottle." + (log.map { " Details are in \($0)." } ?? "")
        case .downloadFailed(let reason):
            return "Downloading the Steam installer failed: \(reason)"
        }
    }
}

/// A program started in a bottle. The process is observed until it exits.
struct RunningProgram: Identifiable {
    let id: UUID
    let bottleID: UUID
    let name: String
    let startedAt: Date
    let logURL: URL
    /// CrossOver writes Wine's own output to a separate log (`--cx-log`).
    let wineLogURL: URL?
    let process: Process
}

/// Bottle operations that run Wine: creating and initializing bottles,
/// applying settings, installing Steam and DXVK, launching programs and
/// stopping them. Everything here blocks or awaits; call it off the main thread.
struct BottleOperations {
    let store: BottleStore
    let gpu: GPUStack
    let crossOverBottleDirectory: URL
    var runner = ProcessRunner()
    /// How long to wait for steam.exe to appear after the installer exits.
    var steamPollTimeout: TimeInterval = 30
    /// Fetches a URL to a local file. Injectable for tests.
    var download: (URL, URL) async throws -> Void = BottleOperations.urlSessionDownload

    /// The official Windows Steam client installer (an NSIS installer).
    static let steamSetupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
    static let steamSilentInstallArguments = ["/S"]

    func planner(for bottle: Bottle, engine: WineEngine) -> LaunchPlanner {
        LaunchPlanner(bottle: bottle, engine: engine, gpu: gpu, crossOverBottleDirectory: crossOverBottleDirectory)
    }

    // MARK: Creating bottles

    /// Creates a SteamXBridge-owned prefix and initializes it with `wineboot --init`.
    /// The bottle is removed again if initialization fails.
    func createPlainBottle(named name: String, engine: WineEngine, windowsVersion: WindowsVersion,
                           settings: BottleSettings) async throws -> Bottle {
        let bottle = try store.createBottle(named: name) {
            $0.engineID = engine.id
            $0.windowsVersion = windowsVersion
            $0.settings = settings
        }
        do {
            let plan = planner(for: bottle, engine: engine)
            let log = store.logURL(for: bottle, program: "create-bottle")
            let result = try await runner.run(try plan.helper(["wineboot", "--init"], displayName: "Create bottle"),
                                              logURL: log, timeout: 600)
            guard result.succeeded, bottle.isInitialized else {
                throw BottleOperationError.initializationFailed(log: log.path)
            }
            if windowsVersion != .win10 {
                try await runChecked(try plan.setWindowsVersion(windowsVersion), bottle: bottle, program: "windows-version")
            }
            if settings.highResolutionMode {
                try await applyHighResolution(true, bottle: bottle, engine: engine)
            }
            return bottle
        } catch {
            try? store.remove(bottle)
            throw error
        }
    }

    /// Creates a bottle with CrossOver's own `cxbottle` tool (so CrossOver
    /// manages it) and adds it to SteamXBridge.
    func createCrossOverBottle(named rawName: String, engine: WineEngine, windowsVersion: WindowsVersion,
                               settings: BottleSettings, existing: [Bottle]) async throws -> Bottle {
        let name = try Self.crossOverBottleName(rawName)
        let cxbottle = try crossOverTool(engine)
        let folder = crossOverBottleDirectory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw BottleOperationError.crossOverBottleExists(name)
        }
        // Use the template CrossOver actually ships (enumerated at runtime), and
        // record the Windows version that template really produces.
        let template = Self.availableTemplate(for: windowsVersion, cxRoot: cxbottle.deletingLastPathComponent().deletingLastPathComponent())
        return try await withCrossOverCleanup(folder: folder, name: name, cxbottle: cxbottle) { link in
            let result = try await runner.run(WineInvocation(
                executable: cxbottle,
                arguments: ["--bottle", name, "--create", "--template", template.name],
                environment: [:],
                workingDirectory: nil,
                displayName: "Create CrossOver bottle"
            ), logURL: store.logsDirectory.appendingPathComponent("crossover-create-\(BottleStore.slug(name)).log"), timeout: 600)
            guard result.succeeded, FileManager.default.fileExists(atPath: folder.path) else {
                throw BottleOperationError.commandFailed("cxbottle", status: result.exitCode, log: result.logURL?.path)
            }
            var bottle = try link(store.linkBottle(prefix: folder, named: name, source: ExternalBottleFinder.crossOverSource, existing: existing))
            bottle.engineID = engine.id
            bottle.windowsVersion = template.version
            bottle.settings = settings
            try store.save(bottle)
            try await applySettings(from: nil, to: bottle, engine: engine)
            return bottle
        }
    }

    /// Duplicates a CrossOver bottle with `cxbottle --copy`, so the copy lives
    /// in CrossOver's bottle folder and CrossOver can run it. (A plain file copy
    /// elsewhere would carry cxbottle.conf but be unreachable by `--bottle`.)
    func duplicateCrossOverBottle(_ source: Bottle, named rawName: String, engine: WineEngine,
                                  existing: [Bottle]) async throws -> Bottle {
        let name = try Self.crossOverBottleName(rawName)
        let cxbottle = try crossOverTool(engine)
        let folder = crossOverBottleDirectory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw BottleOperationError.crossOverBottleExists(name)
        }
        return try await withCrossOverCleanup(folder: folder, name: name, cxbottle: cxbottle) { link in
            let result = try await runner.run(WineInvocation(
                executable: cxbottle,
                arguments: ["--bottle", name, "--copy", source.prefixURL.lastPathComponent],
                environment: [:],
                workingDirectory: nil,
                displayName: "Duplicate CrossOver bottle"
            ), logURL: store.logsDirectory.appendingPathComponent("crossover-copy-\(BottleStore.slug(name)).log"), timeout: 3600)
            guard result.succeeded, FileManager.default.fileExists(atPath: folder.path) else {
                throw BottleOperationError.commandFailed("cxbottle --copy", status: result.exitCode, log: result.logURL?.path)
            }
            var copy = try link(store.linkBottle(prefix: folder, named: name, source: ExternalBottleFinder.crossOverSource, existing: existing))
            copy.engineID = engine.id
            copy.windowsVersion = source.windowsVersion
            copy.settings = source.settings
            copy.pinnedPrograms = BottleStore.rebasedPins(source.pinnedPrograms, from: source.prefixURL, to: folder)
            try store.save(copy)
            return copy
        }
    }

    private func crossOverTool(_ engine: WineEngine) throws -> URL {
        let cxbottle = engine.loaderURL.deletingLastPathComponent().appendingPathComponent("cxbottle")
        guard FileManager.default.isExecutableFile(atPath: cxbottle.path) else {
            throw BottleOperationError.crossOverToolMissing(cxbottle.path)
        }
        return cxbottle
    }

    /// Runs a cxbottle create/copy and, if anything fails, undoes what this call
    /// made: the SteamXBridge record and the half-made bottle in CrossOver's
    /// folder (so a retry under the same name works). The folder did not exist
    /// before the call, so nothing of the user's is touched.
    private func withCrossOverCleanup(folder: URL, name: String, cxbottle: URL,
                                      _ work: (_ link: (Bottle) -> Bottle) async throws -> Bottle) async throws -> Bottle {
        var linked: Bottle?
        do {
            return try await work { bottle in
                linked = bottle
                return bottle
            }
        } catch {
            if let linked { try? store.remove(linked) } // linked: metadata only
            if FileManager.default.fileExists(atPath: folder.path) {
                _ = try? await runner.run(WineInvocation(
                    executable: cxbottle, arguments: ["--bottle", name, "--delete", "--force"],
                    environment: [:], workingDirectory: nil, displayName: "Remove failed CrossOver bottle"
                ), timeout: 120)
                if FileManager.default.fileExists(atPath: folder.path) {
                    #if os(macOS)
                    try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                    #else
                    try? FileManager.default.removeItem(at: folder)
                    #endif
                }
            }
            throw error
        }
    }

    /// The template to create a bottle from: the 64-bit template for the
    /// requested Windows version when CrossOver ships it, else Windows 10.
    static func availableTemplate(for version: WindowsVersion, cxRoot: URL) -> (name: String, version: WindowsVersion) {
        let templates = cxRoot.appendingPathComponent("share/crossover/bottle_templates", isDirectory: true)
        let wanted = crossOverTemplate(for: version)
        let wantedVersion: WindowsVersion = version == .win81 ? .win10 : version
        // When the template folder cannot be listed, trust the conventional names.
        guard FileManager.default.fileExists(atPath: templates.path) else { return (wanted, wantedVersion) }
        if FileManager.default.fileExists(atPath: templates.appendingPathComponent(wanted).path) {
            return (wanted, wantedVersion)
        }
        return ("win10_64", .win10)
    }

    /// CrossOver bottle names are folder names: no slashes, no leading dot.
    static func crossOverBottleName(_ raw: String) throws -> String {
        var name = try BottleStore.validatedName(raw)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { throw BottleStoreError.invalidName }
        return name
    }

    /// 64-bit CrossOver templates (CrossOver 26 deprecates 32-bit bottles).
    static func crossOverTemplate(for version: WindowsVersion) -> String {
        switch version {
        case .win11: return "win11_64"
        case .win10, .win81: return "win10_64"
        case .win7: return "win7_64"
        case .winxp64: return "winxp_64"
        }
    }

    // MARK: Settings

    /// Applies the settings that are not plain launch-time variables: CrossOver's
    /// cxbottle.conf, the Windows version, High Resolution Mode, and DXVK files.
    func applySettings(from old: Bottle?, to bottle: Bottle, engine: WineEngine) async throws {
        if bottle.isCrossOverBottle {
            try writeCrossOverConfig(for: bottle, previous: old, engine: engine)
        }
        if let old, old.windowsVersion != bottle.windowsVersion {
            try await runChecked(try planner(for: bottle, engine: engine).setWindowsVersion(bottle.windowsVersion),
                                 bottle: bottle, program: "windows-version")
        }
        if old?.settings.highResolutionMode != bottle.settings.highResolutionMode,
           old != nil || bottle.settings.highResolutionMode {
            try await applyHighResolution(bottle.settings.highResolutionMode, bottle: bottle, engine: engine)
        }
        try installDXVKIfNeeded(bottle: bottle, engine: engine)
    }

    /// Writes SteamXBridge's keys to cxbottle.conf, atomically. With `previous`,
    /// only keys whose value changed between the two bottles are touched, so a
    /// rename or an unrelated edit never resets choices made in CrossOver.
    /// Without it (a bottle SteamXBridge just created), every key is written.
    func writeCrossOverConfig(for bottle: Bottle, previous: Bottle?, engine: WineEngine) throws {
        let url = bottle.prefixURL.appendingPathComponent("cxbottle.conf")
        var config = CrossOverBottleConfig(contentsOf: url) ?? CrossOverBottleConfig(text: "")
        let changes = planner(for: bottle, engine: engine).crossOverConfigChanges()
        var before: [String: String?] = [:]
        if let previous {
            for change in planner(for: previous, engine: engine).crossOverConfigChanges() where before[change.key] == nil {
                before[change.key] = .some(change.value)
            }
        }
        var touched = false
        for change in changes {
            if previous != nil, let old = before[change.key], old == change.value { continue }
            config.setValue(change.value, section: "EnvironmentVariables", key: change.key)
            touched = true
        }
        guard touched else { return }
        try Data(config.text.utf8).write(to: url, options: .atomic)
    }

    private func applyHighResolution(_ enabled: Bool, bottle: Bottle, engine: WineEngine) async throws {
        let plan = planner(for: bottle, engine: engine)
        for command in plan.highResolutionCommands(enabled: enabled) {
            try await runChecked(try plan.helper(command, displayName: "High Resolution Mode"), bottle: bottle, program: "high-resolution")
        }
    }

    /// Plain engines need DXVK's DLLs copied into the prefix before the
    /// overrides in the launch environment can take effect.
    func installDXVKIfNeeded(bottle: Bottle, engine: WineEngine) throws {
        guard bottle.settings.graphics == .dxvk, !engine.isCrossOver, let source = engine.dxvkSourcePath,
              bottle.isInitialized, !DXVKInstaller.isInstalled(in: bottle.prefixURL) else { return }
        try DXVKInstaller.install(from: URL(fileURLWithPath: source), into: bottle.prefixURL)
    }

    // MARK: Running

    /// Starts a program and returns immediately; `onExit` fires when it ends.
    /// `waitForChildren` is for installers: on CrossOver the run (and its log)
    /// then lasts until every process the installer started has exited.
    func launch(_ target: LaunchTarget, in bottle: Bottle, engine: WineEngine, runID: UUID = UUID(),
                waitForChildren: Bool = false,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningProgram {
        try installDXVKIfNeeded(bottle: bottle, engine: engine)
        let name = target.displayName
        let log = store.logURL(for: bottle, program: name)
        let wineLog = engine.isCrossOver
            ? log.deletingPathExtension().appendingPathExtension("wine.log")
            : nil
        let invocation = try planner(for: bottle, engine: engine)
            .invocation(for: target, wineLogURL: wineLog, waitForChildren: waitForChildren)
        let process = try runner.start(invocation, logURL: log, onExit: onExit)
        return RunningProgram(id: runID, bottleID: bottle.id, name: name, startedAt: Date(), logURL: log, wineLogURL: wineLog, process: process)
    }

    /// Stops every process in the bottle.
    func forceQuit(_ bottle: Bottle, engine: WineEngine) async throws {
        _ = try await runner.run(try planner(for: bottle, engine: engine).forceQuit(),
                                 logURL: store.logURL(for: bottle, program: "force-quit"), timeout: 60)
    }

    /// Simulates a Windows restart (runs RunOnce entries, as installers expect).
    func simulateReboot(_ bottle: Bottle, engine: WineEngine) async throws {
        try await runChecked(try planner(for: bottle, engine: engine).helper(["wineboot"], displayName: "Simulate Reboot"),
                             bottle: bottle, program: "reboot")
    }

    // MARK: Steam

    /// Downloads the Windows Steam installer (cached for a week) and installs
    /// Steam silently into the bottle.
    func installSteam(in bottle: Bottle, engine: WineEngine) async throws -> SteamInstallation {
        let setup = try await steamInstaller()
        let log = store.logURL(for: bottle, program: "install-steam")
        let invocation = try planner(for: bottle, engine: engine)
            .invocation(for: .program(setup, arguments: Self.steamSilentInstallArguments, workingDirectory: nil),
                        wineLogURL: engine.isCrossOver ? log.deletingPathExtension().appendingPathExtension("wine.log") : nil,
                        waitForChildren: true)
        let result = try await runner.run(invocation, logURL: log, timeout: 900)
        // The installer may hand off to a child that finishes writing steam.exe
        // a moment after the wrapper exits, so poll briefly before giving up.
        let deadline = Date().addingTimeInterval(steamPollTimeout)
        while true {
            if let steam = SteamInstallation.locate(inPrefix: bottle.prefixURL) { return steam }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw result.succeeded
            ? BottleOperationError.steamInstallFailed(log: log.path)
            : BottleOperationError.commandFailed("The Steam installer", status: result.exitCode, log: log.path)
    }

    func steamInstaller() async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
        let cached = store.downloadsDirectory.appendingPathComponent("SteamSetup.exe")
        if let modified = (try? fm.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           ((try? fm.attributesOfItem(atPath: cached.path))?[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return cached
        }
        let partial = cached.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try await download(Self.steamSetupURL, partial)
        // A PE executable starts with "MZ"; reject HTML error pages and truncated files.
        guard Self.startsWithMZ(partial) else {
            try? fm.removeItem(at: partial)
            throw BottleOperationError.downloadFailed("the server did not return a Windows installer")
        }
        if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
        try fm.moveItem(at: partial, to: cached)
        return cached
    }

    static func urlSessionDownload(_ source: URL, _ destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: source) { temporary, response, error in
                if let error { return continuation.resume(throwing: BottleOperationError.downloadFailed(error.localizedDescription)) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return continuation.resume(throwing: BottleOperationError.downloadFailed("HTTP \(http.statusCode)"))
                }
                guard let temporary else {
                    return continuation.resume(throwing: BottleOperationError.downloadFailed("no data"))
                }
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    // MARK: Helpers

    static func startsWithMZ(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 2) == Data([0x4D, 0x5A])
    }

    private func runChecked(_ invocation: WineInvocation, bottle: Bottle, program: String) async throws {
        let log = store.logURL(for: bottle, program: program)
        let result = try await runner.run(invocation, logURL: log, timeout: 300)
        guard result.succeeded else {
            throw BottleOperationError.commandFailed(invocation.displayName, status: result.exitCode, log: log.path)
        }
    }
}
