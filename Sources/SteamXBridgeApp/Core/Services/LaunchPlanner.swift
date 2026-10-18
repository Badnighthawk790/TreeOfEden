import Foundation

/// A built-in Windows tool that can be opened in any bottle.
enum WineTool: String, CaseIterable, Identifiable {
    case configuration = "winecfg"
    case controlPanel = "control"
    case gameControllers = "joy.cpl"
    case internetSettings = "inetcpl.cpl"
    case taskManager = "taskmgr"
    case registryEditor = "regedit"
    case commandPrompt = "cmd"
    case explorer = "explorer"

    var id: String { rawValue }

    /// The Windows command line that opens the tool.
    var command: [String] {
        switch self {
        case .gameControllers, .internetSettings: return ["control", rawValue]
        default: return [rawValue]
        }
    }

    var displayName: String {
        switch self {
        case .configuration: return "Wine Configuration"
        case .controlPanel: return "Control Panel"
        case .gameControllers: return "Game Controllers"
        case .internetSettings: return "Internet Settings"
        case .taskManager: return "Task Manager"
        case .registryEditor: return "Registry Editor"
        case .commandPrompt: return "Command Prompt"
        case .explorer: return "File Explorer"
        }
    }

    var systemImage: String {
        switch self {
        case .configuration: return "gearshape.2"
        case .controlPanel: return "slider.horizontal.3"
        case .gameControllers: return "gamecontroller"
        case .internetSettings: return "globe"
        case .taskManager: return "list.bullet.rectangle"
        case .registryEditor: return "tablecells"
        case .commandPrompt: return "terminal"
        case .explorer: return "folder"
        }
    }
}

/// What to run inside a bottle.
enum LaunchTarget: Equatable {
    /// A Windows program by host path: .exe, .msi, .bat/.cmd or .lnk.
    case program(URL, arguments: [String], workingDirectory: URL?)
    /// The Windows Steam client.
    case steamClient(SteamInstallation)
    /// A Steam game, launched through the Windows Steam client so Steam DRM and
    /// Steamworks find a running client.
    case steamGame(appID: String, steam: SteamInstallation)
    case tool(WineTool)

    var displayName: String {
        switch self {
        case .program(let url, _, _): return url.lastPathComponent
        case .steamClient: return "Steam"
        case .steamGame(let appID, _): return "Steam (game \(appID))"
        case .tool(let tool): return tool.displayName
        }
    }
}

enum LaunchPlanError: LocalizedError, Equatable {
    case rosettaMissing
    case crossOverBottleOutsideLibrary(String)
    case crossOverBottleNeedsCrossOver
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .rosettaMissing:
            return "This engine needs Rosetta 2. Install it by running \"\(Rosetta.installCommand)\" in Terminal."
        case .crossOverBottleOutsideLibrary(let folder):
            return "CrossOver can only run bottles in its Bottles folder (\(folder)). Move this bottle into that folder (or import it in CrossOver), then add it again from there."
        case .crossOverBottleNeedsCrossOver:
            return "This is a CrossOver bottle. Run it with a CrossOver engine; another Wine version would upgrade the prefix and can break it for CrossOver."
        case .unsupportedFile(let name):
            return "\(name) is not a Windows program (.exe, .msi, .bat or .lnk)."
        }
    }
}

/// Turns a bottle, its engine and its settings into exact process invocations.
///
/// Plain Wine engines get the prefix and every setting as environment
/// variables. CrossOver is driven through its own wrapper with `--bottle NAME`:
/// it must not be given WINEPREFIX, and its bottle settings live in
/// cxbottle.conf (see `crossOverConfigChanges`), which overrides anything set
/// at launch.
struct LaunchPlanner {
    let bottle: Bottle
    let engine: WineEngine
    let gpu: GPUStack
    /// Folder that holds CrossOver's bottles (where `--bottle NAME` looks).
    var crossOverBottleDirectory: URL?
    var rosettaInstalled = Rosetta.isInstalled

    /// Variables nobody may override through the bottle's custom environment.
    static let reservedVariables: Set<String> = ["WINEPREFIX", "CX_BOTTLE", "CX_ROOT", "WINELOADER", "WINESERVER"]

    /// Keeps Wine from writing macOS app shims and menu entries for every installer.
    static let menuBuilderOverride = "winemenubuilder.exe=d"
    static let dxvkOverride = "dxgi,d3d9,d3d10core,d3d11=n,b"
    static let debugChannels = "+seh,+tid,+loaddll,err+all,fixme-all"

    // MARK: Checks

    /// Problems that would make every launch fail.
    func validate() throws {
        if engine.needsRosetta, !rosettaInstalled { throw LaunchPlanError.rosettaMissing }
        if bottle.isCrossOverBottle, !engine.isCrossOver { throw LaunchPlanError.crossOverBottleNeedsCrossOver }
        if engine.isCrossOver { _ = try crossOverBottleName() }
    }

    /// The name CrossOver knows the bottle by: its folder name inside CrossOver's
    /// bottle directory.
    func crossOverBottleName() throws -> String {
        let library = crossOverBottleDirectory ?? bottle.prefixURL.deletingLastPathComponent()
        guard bottle.prefixURL.deletingLastPathComponent().canonicalPath == library.canonicalPath else {
            throw LaunchPlanError.crossOverBottleOutsideLibrary(library.path)
        }
        return bottle.prefixURL.lastPathComponent
    }

    // MARK: Invocations

    /// The invocation for a program, Steam, a game or a Wine tool.
    /// `wineLogURL` receives Wine's own log for CrossOver (`--cx-log`).
    /// `waitForChildren` keeps CrossOver's wrapper alive until every process the
    /// program started has exited (installers hand off to child processes).
    func invocation(for target: LaunchTarget, wineLogURL: URL? = nil, waitForChildren: Bool = false) throws -> WineInvocation {
        try validate()
        let (command, workingDirectory) = try windowsCommand(for: target)
        return try wrap(command, workingDirectory: workingDirectory, displayName: target.displayName,
                        wineLogURL: wineLogURL, newConsole: target == .tool(.commandPrompt),
                        waitForChildren: waitForChildren)
    }

    /// A helper run in the bottle, such as `["wineboot", "--init"]` or `["reg", "add", ...]`.
    func helper(_ command: [String], displayName: String) throws -> WineInvocation {
        try validate()
        return try wrap(command, workingDirectory: nil, displayName: displayName, wineLogURL: nil, newConsole: false,
                        waitForChildren: false)
    }

    /// Stops every process in the bottle (CrossOver's "Force Quit").
    func forceQuit() throws -> WineInvocation {
        if let wineserver = engine.wineserverPath {
            return WineInvocation(
                executable: URL(fileURLWithPath: wineserver),
                arguments: ["-k"],
                environment: ["WINEPREFIX": bottle.prefixPath],
                workingDirectory: nil,
                displayName: "Force Quit"
            )
        }
        return try helper(["wineboot", "--end-session", "--force", "--kill"], displayName: "Force Quit")
    }

    /// Sets the Windows version reported to programs.
    func setWindowsVersion(_ version: WindowsVersion) throws -> WineInvocation {
        try helper(["winecfg", "/v", version.winecfgValue], displayName: "Set Windows version")
    }

    /// Registry edits for High Resolution Mode: Retina rendering on the Mac
    /// driver plus a 192-DPI desktop (off restores 96 DPI).
    func highResolutionCommands(enabled: Bool) -> [[String]] {
        [
            ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", enabled ? "y" : "n", "/f"],
            ["reg", "add", #"HKCU\Control Panel\Desktop"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", enabled ? "192" : "96", "/f"],
        ]
    }

    /// The Windows-side command line (program plus arguments) for a target.
    func windowsCommand(for target: LaunchTarget) throws -> (command: [String], workingDirectory: URL?) {
        switch target {
        case .program(let url, let arguments, let workingDirectory):
            let folder = workingDirectory ?? url.deletingLastPathComponent()
            switch url.pathExtension.lowercased() {
            case "exe", "com":
                return ([url.path] + arguments, folder)
            case "msi", "bat", "cmd", "lnk":
                // Opened through Windows' shell (ShellExecute): it runs msiexec
                // for .msi, cmd for .bat/.cmd, and a shortcut's own target,
                // arguments and working directory for .lnk. /wait keeps the
                // process (and its log) alive until the program exits.
                if engine.isCrossOver {
                    // CrossOver's wrapper converts native paths in arguments,
                    // which would clash with /unix; a Windows path is left alone.
                    return (["start", "/wait", Self.windowsPath(forHostPath: url.path)] + arguments, folder)
                }
                return (["start", "/wait", "/unix", url.path] + arguments, folder)
            default:
                throw LaunchPlanError.unsupportedFile(url.lastPathComponent)
            }
        case .steamClient(let steam):
            return ([steam.steamExecutable.path] + steamClientArguments, steam.root)
        case .steamGame(let appID, let steam):
            return ([steam.steamExecutable.path] + steamClientArguments + ["-applaunch", appID], steam.root)
        case .tool(.commandPrompt):
            return (["cmd"], nil)
        case .tool(let tool):
            return (tool.command, nil)
        }
    }

    /// Opt-in Steam switches that help the client's web UI on plain WineHQ
    /// builds (it can still render black there; an open upstream bug).
    /// CrossOver handles Steam itself and gets no extra flags.
    static let steamCompatibilityArguments = ["-noverifyfiles", "-no-cef-sandbox", "-cef-single-process"]

    var steamClientArguments: [String] {
        bottle.settings.steamCompatibilityFlags && !engine.isCrossOver ? Self.steamCompatibilityArguments : []
    }

    /// A host path as Wine sees it through drive Z: (which maps to /).
    static func windowsPath(forHostPath path: String) -> String {
        "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    private func wrap(_ command: [String], workingDirectory: URL?, displayName: String,
                      wineLogURL: URL?, newConsole: Bool, waitForChildren: Bool) throws -> WineInvocation {
        if engine.isCrossOver {
            var arguments = ["--bottle", try crossOverBottleName()]
            if waitForChildren { arguments.append("--wait-children") }
            if let wineLogURL { arguments += ["--cx-log", wineLogURL.path] }
            if bottle.settings.debugLogging { arguments += ["--debugmsg", Self.debugChannels] }
            if newConsole { arguments.append("--new-console") }
            // --cx-app runs the first element as the Windows program; native
            // paths in it and in its arguments are converted to Windows paths.
            // Built-in tools are named with their extension, as CrossOver's
            // own examples do (winecfg.exe, reg.exe, cmd.exe).
            var program = command
            if let first = program.first, !first.contains("/"), !first.contains("\\"), !first.contains(".") {
                program[0] = first + ".exe"
            }
            arguments += ["--cx-app"] + program
            return WineInvocation(
                executable: engine.loaderURL,
                arguments: arguments,
                environment: customEnvironment(),
                workingDirectory: workingDirectory,
                displayName: displayName
            )
        }
        let commandLine = newConsole ? ["start"] + command : command
        return WineInvocation(
            executable: engine.loaderURL,
            arguments: commandLine,
            environment: plainEnvironment(),
            workingDirectory: workingDirectory,
            displayName: displayName
        )
    }

    // MARK: Environment

    /// The full environment layered over the app's own for a plain Wine engine.
    func plainEnvironment() -> [String: String] {
        let s = bottle.settings
        var env: [String: String] = [
            "WINEPREFIX": bottle.prefixPath,
            "WINEDEBUG": s.debugLogging ? Self.debugChannels : "-all",
        ]
        let custom = customEnvironment()
        var overrides = [Self.menuBuilderOverride]
        if s.graphics == .dxvk, engine.supports(.dxvk) {
            overrides.append(Self.dxvkOverride)
        }
        // The user's overrides are appended (later entries win in Wine), not
        // allowed to replace DXVK's and the menu-builder override.
        if let user = custom["WINEDLLOVERRIDES"]?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            overrides.append(user)
        }
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")

        if s.msync, engine.supports(.msync) {
            env["WINEMSYNC"] = "1"
            // D3DMetal changes behaviour when it does not see ESync, so MSync
            // is announced together with ESync (as Whisky does).
            if engine.supports(.esync) { env["WINEESYNC"] = "1" }
        } else if s.esync, engine.supports(.esync) {
            env["WINEESYNC"] = "1"
        }
        if s.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        // Read by Rosetta (macOS 15+), so it applies to every x86_64 engine.
        if s.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if engine.supports(.d3dMetal), let dxr = rayTracingValue { env["D3DM_SUPPORT_DXR"] = dxr }
        for (key, value) in custom where key != "WINEDLLOVERRIDES" { env[key] = value }
        return env
    }

    /// D3DM_SUPPORT_DXR for this bottle, or nil to leave D3DMetal's default
    /// (on for M3 and newer, off for M1/M2). Never set without RT hardware.
    var rayTracingValue: String? {
        guard gpu.hasHardwareRayTracing else { return nil }
        switch bottle.settings.rayTracing {
        case .automatic: return nil
        case .on: return "1"
        case .off: return "0"
        }
    }

    /// The bottle's custom variables, minus invalid names and reserved keys.
    func customEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for variable in bottle.settings.environment {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            guard Self.isValidEnvironmentName(name), !Self.reservedVariables.contains(name) else { continue }
            env[name] = variable.value
        }
        return env
    }

    /// cxbottle.conf `[EnvironmentVariables]` changes that express this bottle's
    /// settings the way CrossOver 26 stores them. A nil value removes the key
    /// (for CX_GRAPHICS_BACKEND that means Auto).
    func crossOverConfigChanges() -> [(key: String, value: String?)] {
        let s = bottle.settings
        let backend: String?
        switch s.graphics {
        case .automatic: backend = nil
        case .d3dMetal: backend = "d3dmetal"
        case .dxmt: backend = "dxmt"
        case .dxvk: backend = "dxvk"
        case .wineD3D: backend = "wined3d"
        }
        let dlss = s.dlssMetalFX && engine.supports(.dlssMetalFX)
        let usesD3DMetal = s.graphics == .automatic || s.graphics == .d3dMetal
        let usesDXMT = s.graphics == .automatic || s.graphics == .dxmt
        var changes: [(key: String, value: String?)] = [
            ("CX_GRAPHICS_BACKEND", backend),
            ("WINEMSYNC", s.msync ? "1" : nil),
            ("D3DM_ENABLE_METALFX", dlss && usesD3DMetal ? "1" : nil),
            ("DXMT_ENABLE_NVEXT", dlss && usesDXMT ? "1" : nil),
            ("MTL_HUD_ENABLED", s.metalHUD ? "1" : nil),
            ("D3DM_SUPPORT_DXR", rayTracingValue),
            // Written both ways: reports disagree on the wrapper's own default.
            ("ROSETTA_ADVERTISE_AVX", s.advertiseAVX ? "1" : "0"),
        ]
        // Only CrossOver 25 and earlier still have ESync; never touch the key on 26.
        if engine.supports(.esync) {
            changes.append(("WINEESYNC", s.esync && !s.msync ? "1" : nil))
        }
        return changes
    }

    /// An ASCII letter or underscore followed by letters, digits or underscores.
    static func isValidEnvironmentName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else { return false }
        func isAlpha(_ v: UInt32) -> Bool { (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 }
        func isDigit(_ v: UInt32) -> Bool { v >= 48 && v <= 57 }
        return isAlpha(first.value) && scalars.allSatisfy { isAlpha($0.value) || isDigit($0.value) }
    }
}

extension Bottle {
    /// True for bottles CrossOver created (they carry a cxbottle.conf).
    var isCrossOverBottle: Bool {
        FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("cxbottle.conf").path)
    }

    /// Problems worth showing before the user runs anything in this bottle.
    func warnings(engine: WineEngine?) -> [String] {
        var result: [String] = []
        guard let config = CrossOverBottleConfig(contentsOf: prefixURL.appendingPathComponent("cxbottle.conf")) else {
            return result
        }
        if config.value(section: "Bottle", key: "WineArch")?.lowercased() == "win32" {
            result.append("This is a 32-bit bottle. Current Steam needs a 64-bit bottle, and CrossOver 27 will not open 32-bit bottles. Create a new 64-bit bottle for games.")
        }
        if let engine, engine.isCrossOver,
           let bottleVersion = config.value(section: "Bottle", key: "Version"), let engineVersion = engine.version,
           Self.compareVersions(bottleVersion, engineVersion) == .orderedDescending {
            result.append("This bottle was last used by CrossOver \(bottleVersion), newer than the installed \(engine.name). Update CrossOver; an older version can fail silently on it.")
        }
        return result
    }

    /// Compares dotted version strings numerically ("26.10" > "26.9").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
