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
