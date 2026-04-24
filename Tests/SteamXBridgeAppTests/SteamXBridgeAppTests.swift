import XCTest
@testable import SteamXBridgeApp

final class SteamXBridgeAppTests: XCTestCase {
    func testEnvironmentOverridesAreApplied() {
        let profile = LaunchProfile(
            name: "Test",
            gameExecutablePath: "C:/game.exe",
            useDXVK: true,
            customEnv: "DXVK_ASYNC=0\nMY_FLAG=enabled"
        )

        let env = profile.launchEnvironment
        XCTAssertEqual(env["DXVK_ASYNC"], "0")
        XCTAssertEqual(env["MY_FLAG"], "enabled")
        XCTAssertEqual(env["PROTON_USE_WINED3D"], "0")
    }

    func testSteamAppIDAloneIsValidProfile() {
        let profile = LaunchProfile(
            name: "Steam Launch",
            steamAppID: "123456",
            gameExecutablePath: ""
        )

        XCTAssertTrue(profile.isValid)
    }

    func testLowResourceModeAddsExpectedVariables() {
        let profile = LaunchProfile(
            name: "Low Resource",
            gameExecutablePath: "/Games/game.exe",
            frameLimit: 144,
            lowResourceMode: true
        )

        let env = profile.launchEnvironment
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertEqual(env["DXVK_FRAME_RATE"], "60")
    }

    func testGenerateLaunchCommandHasNoShebang() {
        let profile = LaunchProfile(name: "Command", gameExecutablePath: "/Games/cmd.exe")
        let command = SteamRuntimeService().generateLaunchCommand(
            profile: profile,
            runtimeBinary: "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
        )

        XCTAssertFalse(command.contains("#!/bin/zsh"))
        XCTAssertTrue(command.contains("export WINEPREFIX"))
    }

    func testLaunchScriptContainsRuntimeAndExecutable() {
        let profile = LaunchProfile(name: "Halo MCC", gameExecutablePath: "/Games/HaloMCC.exe")
        let script = SteamRuntimeService().generateLaunchScript(
            profile: profile,
            runtimeBinary: "/Applications/Whisky.app/Contents/Resources/wine/bin/wine64"
        )

        XCTAssertTrue(script.contains("arch -x86_64"))
        XCTAssertTrue(script.contains("HaloMCC.exe"))
    }
}
