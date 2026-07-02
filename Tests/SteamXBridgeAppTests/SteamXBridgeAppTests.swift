import XCTest
@testable import SteamXBridgeApp

final class SteamXBridgeAppTests: XCTestCase {
    func testGPTKBackendEmitsMetalEnvironment() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            backend: .gptkD3DMetal,
            syncPrimitive: .msync
        )
        let env = profile.launchEnvironment
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "0")
        XCTAssertNil(env["DXVK_ASYNC"], "DXVK vars should not leak into the D3DMetal path")
    }

    func testDXVKBackendEmitsDXVKEnvironment() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            backend: .wineDXVK,
            useAsyncShaders: true,
            frameLimit: 45
        )
        let env = profile.launchEnvironment
        XCTAssertEqual(env["DXVK_ASYNC"], "1")
        XCTAssertEqual(env["DXVK_FRAME_RATE"], "45")
        XCTAssertEqual(env["MVK_CONFIG_RESUME_LOST_DEVICE"], "1")
    }

    func testFSRUpscalingEnvironment() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            upscaler: .fsr,
            resolutionScalePercent: 70
        )
        let env = profile.launchEnvironment
        XCTAssertEqual(env["WINE_FULLSCREEN_FSR"], "1")
        XCTAssertEqual(env["WINE_FULLSCREEN_FSR_STRENGTH"], "3") // (100 - 70) / 10
    }

    func testCustomEnvOverridesDefaults() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            backend: .gptkD3DMetal,
            showFPSOverlay: false,
            customEnv: "MTL_HUD_ENABLED=1\nMY_FLAG=on"
        )
        let env = profile.launchEnvironment
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["MY_FLAG"], "on")
    }

    func testHelldivers2IsBlockedByAppID() {
        let entry = GameCompatibility.lookup(appID: "553850", name: "")
        XCTAssertEqual(entry?.status, .blocked)
        XCTAssertEqual(entry?.antiCheat, "nProtect GameGuard")
    }

    func testHelldivers2IsBlockedByName() {
        let entry = GameCompatibility.lookup(appID: "", name: "HELLDIVERS 2")
        XCTAssertEqual(entry?.title, "Helldivers 2")
        XCTAssertEqual(entry?.status, .blocked)
    }

    func testUnknownGameReturnsNil() {
        XCTAssertNil(GameCompatibility.lookup(appID: "999999", name: "Totally Unknown Game"))
    }

    func testBalancedPresetTargets60() {
        var profile = LaunchProfile(name: "Test", gameExecutablePath: "/g.exe", backend: .gptkD3DMetal)
        PerformancePreset.balanced60.apply(to: &profile)
        XCTAssertEqual(profile.frameLimit, 60)
        XCTAssertEqual(profile.resolutionScalePercent, 77)
        XCTAssertEqual(profile.upscaler, .metalFX)
    }

    func testMetalFXOnDXVKProducesWarning() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            backend: .wineDXVK,
            upscaler: .metalFX
        )
        XCTAssertFalse(profile.validationWarnings.isEmpty)
    }

    func testLaunchScriptContainsRuntimeAndExecutable() {
        let profile = LaunchProfile(name: "Halo MCC", gameExecutablePath: "/Games/HaloMCC.exe")
        let script = SteamRuntimeService().generateLaunchScript(
            profile: profile,
            runtimeBinary: "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
        )

        XCTAssertTrue(script.contains("arch -x86_64"))
        XCTAssertTrue(script.contains("HaloMCC.exe"))
        // Env values are shell-escaped, so the export reads WINEMSYNC='1'.
        XCTAssertTrue(script.contains("export WINEMSYNC="))
    }

    func testVDFParsesNestedObject() {
        let text = """
        "AppState"
        {
            "appid"  "220"
            "name"   "Half-Life 2"
            "installdir"  "Half-Life 2"
        }
        """
        let node = VDFParser.parse(text)
        XCTAssertEqual(node["AppState"]?["appid"]?.stringValue, "220")
        XCTAssertEqual(node["AppState"]?["name"]?.stringValue, "Half-Life 2")
        XCTAssertEqual(node["AppState"]?["installdir"]?.stringValue, "Half-Life 2")
    }

    func testScannerFindsInstalledApps() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("steamtest-\(UUID().uuidString)")
        let steamapps = root.appendingPathComponent("steamapps")
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let libraryFolders = """
        "libraryfolders"
        {
            "0"
            {
                "path"  "\(root.path)"
            }
        }
        """
        try libraryFolders.write(
            to: steamapps.appendingPathComponent("libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = """
        "AppState"
        {
            "appid"  "220"
            "name"   "Half-Life 2"
            "installdir"  "Half-Life 2"
        }
        """
        try manifest.write(
            to: steamapps.appendingPathComponent("appmanifest_220.acf"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = SteamLibraryScanner(steamRoot: root)
        let apps = scanner.installedApps()
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.appID, "220")
        XCTAssertEqual(apps.first?.name, "Half-Life 2")
        XCTAssertTrue(apps.first?.installPath.hasSuffix("common/Half-Life 2") ?? false)
    }

    func testExecutableCandidatesSkipKnownNonGameBinaries() throws {
        let fm = FileManager.default
        let installDir = fm.temporaryDirectory.appendingPathComponent("game-\(UUID().uuidString)")
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: installDir) }

        try "game-binary".write(to: installDir.appendingPathComponent("Game.exe"), atomically: true, encoding: .utf8)
        try "redist".write(to: installDir.appendingPathComponent("vcredist_x64.exe"), atomically: true, encoding: .utf8)

        let app = SteamApp(appID: "1", name: "Game", installDir: "Game", installPath: installDir.path)
        let scanner = SteamLibraryScanner(steamRoot: fm.temporaryDirectory)
        let candidates = scanner.executableCandidates(for: app)
        XCTAssertTrue(candidates.contains { $0.hasSuffix("Game.exe") })
        XCTAssertFalse(candidates.contains { $0.lowercased().contains("vcredist") })
    }

    func testEnvNameValidation() {
        XCTAssertTrue(LaunchProfile.isValidEnvName("DXVK_HUD"))
        XCTAssertTrue(LaunchProfile.isValidEnvName("_x1"))
        XCTAssertFalse(LaunchProfile.isValidEnvName(""))
        XCTAssertFalse(LaunchProfile.isValidEnvName("1ABC"))
        XCTAssertFalse(LaunchProfile.isValidEnvName("A B"))
        XCTAssertFalse(LaunchProfile.isValidEnvName("A;B"))
    }

    func testMaliciousCustomEnvKeyIsRejected() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "/g.exe",
            customEnv: "GOOD_KEY=1\nFOO; rm -rf ~ ; X=2\nBAD-KEY=3\n$(evil)=4"
        )
        let env = profile.launchEnvironment
        XCTAssertEqual(env["GOOD_KEY"], "1")
        XCTAssertNil(env["FOO; rm -rf ~ ; X"])
        XCTAssertNil(env["BAD-KEY"])
        // No key should carry shell metacharacters into the generated script.
        XCTAssertFalse(env.keys.contains { $0.contains(";") || $0.contains("$") || $0.contains("-") || $0.contains(" ") })
    }

    func testVDFTreatsQuotedBracesAsLiterals() {
        let text = """
        "root"
        {
            "a"  "{"
            "b"  "value"
        }
        """
        let node = VDFParser.parse(text)
        XCTAssertEqual(node["root"]?["a"]?.stringValue, "{")
        XCTAssertEqual(node["root"]?["b"]?.stringValue, "value")
    }
}
