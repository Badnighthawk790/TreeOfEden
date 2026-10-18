import XCTest
@testable import SteamXBridgeApp

final class LaunchPlannerTests: XCTestCase {
    private let m2 = GPUStack.parse(brand: "Apple M2")
    private let m4 = GPUStack.parse(brand: "Apple M4")

    private func plainEngine(_ features: [EngineFeature] = [.d3dMetal, .wineD3D, .msync, .esync, .dxvk],
                             architectures: [CPUArchitecture] = [.x86_64]) -> WineEngine {
        WineEngine(kind: .gamePortingToolkit, name: "GPTK", version: "3.0", loaderPath: "/engines/gptk/bin/wine64",
                   wineserverPath: "/engines/gptk/bin/wineserver", bundlePath: nil, dxvkSourcePath: nil,
                   architectures: architectures, features: features)
    }

    private func crossOverEngine() -> WineEngine {
        WineEngine(kind: .crossOver, name: "CrossOver 26.3.0", version: "26.3.0",
                   loaderPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine",
                   wineserverPath: nil, bundlePath: "/Applications/CrossOver.app", dxvkSourcePath: nil,
                   architectures: [], features: [.d3dMetal, .dxmt, .dxvk, .wineD3D, .msync, .dlssMetalFX])
    }

    func testPlainEngineRunsTheExecutableFromItsFolderWithPrefixAndSettings() throws {
        var bottle = Bottle(name: "Games", prefixPath: "/bottles/games")
        bottle.settings.metalHUD = true
        bottle.settings.dlssMetalFX = true
        let planner = LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: true)

        let game = URL(fileURLWithPath: "/bottles/games/drive_c/Games/Foo Bar/foo.exe")
        let inv = try planner.invocation(for: .program(game, arguments: ["-windowed"], workingDirectory: nil))
        XCTAssertEqual(inv.executable.path, "/engines/gptk/bin/wine64")
        XCTAssertEqual(inv.arguments, [game.path, "-windowed"], "no shell, no arch -x86_64")
        XCTAssertEqual(inv.workingDirectory?.path, "/bottles/games/drive_c/Games/Foo Bar", "cwd is the game's folder")
        XCTAssertEqual(inv.environment["WINEPREFIX"], "/bottles/games")
        XCTAssertEqual(inv.environment["WINEMSYNC"], "1")
        XCTAssertEqual(inv.environment["WINEESYNC"], "1", "D3DMetal expects ESync alongside MSync")
        XCTAssertEqual(inv.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertNil(inv.environment["D3DM_ENABLE_METALFX"], "standalone GPTK needs manual nvngx steps, so DLSS->MetalFX is CrossOver-only")
        XCTAssertEqual(inv.environment["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertEqual(inv.environment["WINEDEBUG"], "-all")
        XCTAssertEqual(inv.environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        for removed in ["WINE_FULLSCREEN_FSR", "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "MTL_SHADER_VALIDATION", "WINEFSYNC"] {
            XCTAssertNil(inv.environment[removed], "\(removed) is a no-op on macOS engines and is no longer emitted")
        }
    }

    func testRayTracingIsThreeWayAndNeedsHardware() throws {
        var bottle = Bottle(name: "B", prefixPath: "/p")
        func dxr(_ mode: RayTracingMode, _ gpu: GPUStack) -> String? {
            bottle.settings.rayTracing = mode
            return LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: gpu, rosettaInstalled: true).plainEnvironment()["D3DM_SUPPORT_DXR"]
        }
        XCTAssertNil(dxr(.on, m2), "M1/M2 have no RT hardware, so DXR is never set")
        XCTAssertNil(dxr(.automatic, m4), "automatic leaves D3DMetal's per-chip default")
        XCTAssertEqual(dxr(.on, m4), "1")
        XCTAssertEqual(dxr(.off, m4), "0", "off really disables it on M3 and newer")
    }

    func testDXVKOverridesOnlyWhenTheEngineCanSupplyDXVK() {
        var bottle = Bottle(name: "B", prefixPath: "/p")
        bottle.settings.graphics = .dxvk
        let with = LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: true).plainEnvironment()
        XCTAssertEqual(with["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;dxgi,d3d9,d3d10core,d3d11=n,b")
        let without = LaunchPlanner(bottle: bottle, engine: plainEngine([.d3dMetal, .msync]), gpu: m2, rosettaInstalled: true).plainEnvironment()
        XCTAssertEqual(without["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
    }

    func testCustomEnvironmentIsValidatedAndCannotRetargetThePrefix() {
        var bottle = Bottle(name: "B", prefixPath: "/p")
        bottle.settings.environment = [
            EnvironmentVariable(name: "DXVK_HUD", value: "fps"),
            EnvironmentVariable(name: "WINEPREFIX", value: "/somewhere/else"),
            EnvironmentVariable(name: "FOO; rm -rf ~", value: "1"),
            EnvironmentVariable(name: "1BAD", value: "1"),
        ]
        let env = LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: true).plainEnvironment()
        XCTAssertEqual(env["DXVK_HUD"], "fps")
        XCTAssertEqual(env["WINEPREFIX"], "/p")
        XCTAssertNil(env["FOO; rm -rf ~"])
        XCTAssertNil(env["1BAD"])
    }

    func testFileTypesAndTools() throws {
        let planner = LaunchPlanner(bottle: Bottle(name: "B", prefixPath: "/p"), engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        func command(_ path: String) throws -> [String] {
            try planner.windowsCommand(for: .program(URL(fileURLWithPath: path), arguments: [], workingDirectory: nil)).command
        }
        XCTAssertEqual(try command("/x/setup.msi"), ["msiexec", "/i", "/x/setup.msi"])
        XCTAssertEqual(try command("/x/run.bat"), ["cmd", "/c", "/x/run.bat"])
        XCTAssertEqual(try command("/x/Game.lnk"), ["start", "/wait", "/unix", "/x/Game.lnk"])
        XCTAssertThrowsError(try command("/x/readme.txt"))
        XCTAssertEqual(try planner.invocation(for: .tool(.registryEditor)).arguments, ["regedit"])
        XCTAssertEqual(try planner.invocation(for: .tool(.commandPrompt)).arguments, ["start", "cmd"], "a console window, not the app's null stdin")
    }

    func testSteamGamesLaunchThroughTheSteamClient() throws {
        let steam = SteamInstallation(prefix: URL(fileURLWithPath: "/p"),
                                      root: URL(fileURLWithPath: "/p/drive_c/Program Files (x86)/Steam"))
        let planner = LaunchPlanner(bottle: Bottle(name: "B", prefixPath: "/p"), engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        let inv = try planner.invocation(for: .steamGame(appID: "553850", steam: steam))
        XCTAssertEqual(inv.arguments.first, steam.steamExecutable.path)
        XCTAssertEqual(Array(inv.arguments.suffix(2)), ["-applaunch", "553850"])
        XCTAssertEqual(inv.workingDirectory, steam.root)
    }

    func testCrossOverUsesItsWrapperWithBottleNameAndNoPrefix() throws {
        var bottle = Bottle(name: "Steam", prefixPath: "/Users/me/Library/Application Support/CrossOver/Bottles/Steam", origin: .linked)
        bottle.settings.debugLogging = true
        let planner = LaunchPlanner(bottle: bottle, engine: crossOverEngine(), gpu: m2,
                                    crossOverBottleDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/CrossOver/Bottles"),
                                    rosettaInstalled: false)
        let exe = URL(fileURLWithPath: "/Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Games/a.exe")
        let inv = try planner.invocation(for: .program(exe, arguments: ["-x"], workingDirectory: nil),
                                         wineLogURL: URL(fileURLWithPath: "/logs/a-wine.log"))
        XCTAssertEqual(inv.executable.path, "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        XCTAssertEqual(inv.arguments, ["--bottle", "Steam", "--cx-log", "/logs/a-wine.log",
                                       "--debugmsg", LaunchPlanner.debugChannels, "--cx-app", exe.path, "-x"])
        XCTAssertNil(inv.environment["WINEPREFIX"], "CrossOver must not be given WINEPREFIX")
        XCTAssertEqual(try planner.invocation(for: .tool(.configuration)).arguments.suffix(2), ["--cx-app", "winecfg.exe"])
        XCTAssertEqual(try planner.invocation(for: .tool(.commandPrompt)).arguments.suffix(3), ["--new-console", "--cx-app", "cmd.exe"])
        XCTAssertEqual(try planner.helper(["reg", "add", "K"], displayName: "reg").arguments.suffix(4), ["--cx-app", "reg.exe", "add", "K"])
    }

    func testCrossOverCannotRunBottlesOutsideItsLibrary() {
        let planner = LaunchPlanner(bottle: Bottle(name: "Mine", prefixPath: "/elsewhere/mine"), engine: crossOverEngine(), gpu: m2,
                                    crossOverBottleDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/CrossOver/Bottles"),
                                    rosettaInstalled: true)
        XCTAssertThrowsError(try planner.validate()) {
            guard case .crossOverBottleOutsideLibrary = $0 as? LaunchPlanError else { return XCTFail("\($0)") }
        }
    }

    func testCrossOverBottlesRefusePlainEngines() throws {
        let tmp = try TemporaryDirectory()
        let prefix = try tmp.directory("Bottles/Steam")
        try tmp.file("Bottles/Steam/cxbottle.conf", contents: "[Bottle]\n")
        let planner = LaunchPlanner(bottle: Bottle(name: "Steam", prefixPath: prefix.path, origin: .linked),
                                    engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        XCTAssertThrowsError(try planner.validate()) { XCTAssertEqual($0 as? LaunchPlanError, .crossOverBottleNeedsCrossOver) }
    }

    func testRosettaIsRequiredOnlyForX86OnlyLoaders() {
        let bottle = Bottle(name: "B", prefixPath: "/p")
        XCTAssertThrowsError(try LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: false).validate()) {
            XCTAssertEqual($0 as? LaunchPlanError, .rosettaMissing)
        }
        XCTAssertNoThrow(try LaunchPlanner(bottle: bottle, engine: plainEngine(architectures: [.arm64]), gpu: m2, rosettaInstalled: false).validate())
    }

    func testCrossOverConfigChangesMirrorCrossOver26Keys() {
        var bottle = Bottle(name: "Steam", prefixPath: "/b/Steam")
        bottle.settings.graphics = .d3dMetal
        bottle.settings.dlssMetalFX = true
        bottle.settings.msync = false
        bottle.settings.advertiseAVX = true
        let changes = Dictionary(uniqueKeysWithValues: LaunchPlanner(bottle: bottle, engine: crossOverEngine(), gpu: m2, rosettaInstalled: true)
            .crossOverConfigChanges().map { ($0.key, $0.value) })
        XCTAssertEqual(changes["CX_GRAPHICS_BACKEND"], .some("d3dmetal"))
        XCTAssertEqual(changes["D3DM_ENABLE_METALFX"], .some("1"))
        XCTAssertEqual(changes["DXMT_ENABLE_NVEXT"], .some(nil), "DLSS via DXMT does not apply to a D3DMetal bottle")
        XCTAssertEqual(changes["WINEMSYNC"], .some(nil))
        XCTAssertEqual(changes["ROSETTA_ADVERTISE_AVX"], .some("1"), "written explicitly in both directions")

        bottle.settings.graphics = .automatic
        let auto = Dictionary(uniqueKeysWithValues: LaunchPlanner(bottle: bottle, engine: crossOverEngine(), gpu: m2, rosettaInstalled: true)
            .crossOverConfigChanges().map { ($0.key, $0.value) })
        XCTAssertEqual(auto["CX_GRAPHICS_BACKEND"], .some(nil), "Auto is the key removed")
    }

    func testControlPanelsAndSteamCompatibilityFlags() throws {
        var bottle = Bottle(name: "B", prefixPath: "/p")
        let steam = SteamInstallation(prefix: URL(fileURLWithPath: "/p"), root: URL(fileURLWithPath: "/p/drive_c/Program Files (x86)/Steam"))
        let plain = LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        XCTAssertEqual(try plain.invocation(for: .tool(.gameControllers)).arguments, ["control", "joy.cpl"])
        XCTAssertEqual(try plain.invocation(for: .steamClient(steam)).arguments, [steam.steamExecutable.path], "no switches by default")

        bottle.settings.steamCompatibilityFlags = true
        let flagged = LaunchPlanner(bottle: bottle, engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        XCTAssertEqual(try flagged.invocation(for: .steamGame(appID: "10", steam: steam)).arguments,
                       [steam.steamExecutable.path] + LaunchPlanner.steamCompatibilityArguments + ["-applaunch", "10"])
    }

    func testBottleWarningsForLegacyAndNewerCrossOverBottles() throws {
        let tmp = try TemporaryDirectory()
        let prefix = try tmp.directory("Bottles/Old")
        try tmp.file("Bottles/Old/cxbottle.conf", contents: "[Bottle]\n\"WineArch\" = \"win32\"\n\"Version\" = \"26.10.0.1\"\n")
        let bottle = Bottle(name: "Old", prefixPath: prefix.path, origin: .linked)
        let older = WineEngine(kind: .crossOver, name: "CrossOver 26.3.0", version: "26.3.0", loaderPath: "/x/wine",
                               wineserverPath: nil, bundlePath: nil, dxvkSourcePath: nil, architectures: [], features: [])
        let warnings = bottle.warnings(engine: older)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].contains("32-bit"))
        XCTAssertTrue(warnings[1].contains("26.10.0.1"))
        XCTAssertTrue(Bottle(name: "Plain", prefixPath: try tmp.directory("plain").path).warnings(engine: older).isEmpty)
        XCTAssertEqual(Bottle.compareVersions("26.10", "26.9"), .orderedDescending)
        XCTAssertEqual(Bottle.compareVersions("26.3.0", "26.3"), .orderedSame)
    }

    func testHighResolutionRegistryCommands() {
        let planner = LaunchPlanner(bottle: Bottle(name: "B", prefixPath: "/p"), engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        let on = planner.highResolutionCommands(enabled: true)
        XCTAssertTrue(on[0].contains("RetinaMode") && on[0].contains("y"))
        XCTAssertTrue(on[1].contains("LogPixels") && on[1].contains("192"))
        XCTAssertTrue(planner.highResolutionCommands(enabled: false)[1].contains("96"))
    }

    func testForceQuitUsesTheEnginesOwnWineserver() throws {
        let planner = LaunchPlanner(bottle: Bottle(name: "B", prefixPath: "/p"), engine: plainEngine(), gpu: m2, rosettaInstalled: true)
        let quit = try planner.forceQuit()
        XCTAssertEqual(quit.executable.path, "/engines/gptk/bin/wineserver")
        XCTAssertEqual(quit.arguments, ["-k"])
        XCTAssertEqual(quit.environment["WINEPREFIX"], "/p")
    }
}
