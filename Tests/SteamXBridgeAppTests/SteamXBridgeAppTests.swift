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
        XCTAssertTrue(script.contains("export WINEMSYNC=1"))
    }
}
