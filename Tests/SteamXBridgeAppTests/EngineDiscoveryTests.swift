import XCTest
@testable import SteamXBridgeApp

final class EngineDiscoveryTests: XCTestCase {
    private let x86Loader = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01, 0, 0, 0, 0])
    private let armLoader = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0])

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func makeCrossOver(_ tmp: TemporaryDirectory, at path: String, identifier: String, version: String) throws {
        try tmp.file("\(path)/Contents/Info.plist", data: plist([
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
        ]))
        try tmp.file("\(path)/Contents/SharedSupport/CrossOver/bin/wine", contents: "#!/usr/bin/perl\n", executable: true)
        try tmp.file("\(path)/Contents/SharedSupport/CrossOver/bin/wineserver", data: x86Loader, executable: true)
    }

    func testDiscoversEveryEngineKind() throws {
        let tmp = try TemporaryDirectory()
        let apps = try tmp.directory("Applications")
        let home = try tmp.directory("home")

        try makeCrossOver(tmp, at: "Applications/CrossOver.app", identifier: "com.codeweavers.CrossOver", version: "26.3.0")
        try makeCrossOver(tmp, at: "Applications/CrossOver Preview.app", identifier: "com.codeweavers.CrossOverPreview", version: "27.0.0")

        try tmp.file("Applications/Wine Stable.app/Contents/Info.plist", data: plist(["CFBundleShortVersionString": "11.0"]))
        try tmp.file("Applications/Wine Stable.app/Contents/Resources/wine/bin/wine", data: x86Loader, executable: true)
        try tmp.file("Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64", data: x86Loader, executable: true)
        try tmp.file("Applications/Wine Stable.app/Contents/Resources/wine/bin/wineserver", data: x86Loader, executable: true)

        try tmp.file("Applications/Game Porting Toolkit.app/Contents/Info.plist", data: plist(["CFBundleShortVersionString": "3.0"]))
        try tmp.file("Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64", data: x86Loader, executable: true)
        try tmp.directory("Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/D3DMetal.framework")

        let whisky = "home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
        try tmp.file("\(whisky)/Wine/bin/wine64", data: x86Loader, executable: true)
        try tmp.directory("\(whisky)/Wine/lib/external/D3DMetal.framework")
        try tmp.directory("\(whisky)/DXVK/x64")
        try tmp.file("\(whisky)/WhiskyWineVersion.plist", data: plist(["version": ["major": 2, "minor": 5, "patch": 0]]))

        try tmp.file("home/Applications/Sikarugir/Diablo.app/Contents/SharedSupport/wine/bin/wine", data: armLoader, executable: true)

        let engines = EngineDiscovery(home: home, applicationDirectories: [apps]).discover()
        let byKind = Dictionary(grouping: engines, by: \.kind)

        let crossOver = try XCTUnwrap(byKind[.crossOver]?.first)
        XCTAssertEqual(crossOver.name, "CrossOver 26.3.0")
        XCTAssertEqual(crossOver.majorVersion, 26)
        XCTAssertTrue(crossOver.isCrossOver)
        XCTAssertEqual(crossOver.architectures, [], "the wrapper is a script")
        XCTAssertTrue(crossOver.supports(.d3dMetal) && crossOver.supports(.dxmt) && crossOver.supports(.msync))
        XCTAssertFalse(crossOver.supports(.esync), "CrossOver 26 removed ESync")
        XCTAssertNotNil(crossOver.wineserverPath)

        let preview = try XCTUnwrap(byKind[.crossOverPreview]?.first)
        XCTAssertFalse(preview.supports(.d3dMetal), "the ARM64 Preview has no D3DMetal")

        let wine = try XCTUnwrap(byKind[.wineHQ]?.first)
        XCTAssertEqual(wine.name, "Wine Stable 11.0")
        XCTAssertTrue(wine.loaderPath.hasSuffix("/bin/wine"), "wine is preferred over wine64")
        XCTAssertTrue(wine.needsRosetta)

        let gptk = try XCTUnwrap(byKind[.gamePortingToolkit]?.first)
        XCTAssertTrue(gptk.loaderPath.hasSuffix("/bin/wine64"))
        XCTAssertTrue(gptk.supports(.d3dMetal))

        let whiskyWine = try XCTUnwrap(byKind[.whisky]?.first)
        XCTAssertEqual(whiskyWine.version, "2.5.0")
        XCTAssertTrue(whiskyWine.supports(.dxvk))
        XCTAssertNotNil(whiskyWine.dxvkSourcePath)
        XCTAssertEqual(whiskyWine.graphicsBackends, [.automatic, .dxvk], "plain engines can only swap their built-in D3D for DXVK")
        XCTAssertEqual(whiskyWine.automaticGraphicsDescription, "D3DMetal")
        XCTAssertEqual(crossOver.graphicsBackends, [.automatic, .d3dMetal, .dxmt, .dxvk, .wineD3D])

        let sikarugir = try XCTUnwrap(byKind[.sikarugir]?.first)
        XCTAssertEqual(sikarugir.name, "Sikarugir: Diablo")
        XCTAssertFalse(sikarugir.needsRosetta)
    }

    func testRejectsImpostorCrossOverBundles() throws {
        let tmp = try TemporaryDirectory()
        let apps = try tmp.directory("Applications")
        try makeCrossOver(tmp, at: "Applications/CrossOver.app", identifier: "com.example.notcodeweavers", version: "99")
        XCTAssertTrue(EngineDiscovery(home: try tmp.directory("home"), applicationDirectories: [apps]).discover().isEmpty)
    }

    func testOlderCrossOverStillOffersESync() throws {
        let tmp = try TemporaryDirectory()
        let apps = try tmp.directory("Applications")
        try makeCrossOver(tmp, at: "Applications/CrossOver.app", identifier: "com.codeweavers.CrossOver", version: "24.0.7")
        let engine = try XCTUnwrap(EngineDiscovery(home: try tmp.directory("home"), applicationDirectories: [apps]).discover().first)
        XCTAssertTrue(engine.supports(.esync))
        XCTAssertFalse(engine.supports(.dxmt), "DXMT arrived in CrossOver 25")
    }

    func testCrossOverBottleDirectoryHonorsPreference() throws {
        let tmp = try TemporaryDirectory()
        let home = try tmp.directory("home")
        let discovery = EngineDiscovery(home: home, applicationDirectories: [])
        XCTAssertEqual(discovery.crossOverBottleDirectory().path,
                       home.appendingPathComponent("Library/Application Support/CrossOver/Bottles").path)
        try tmp.file("home/Library/Preferences/com.codeweavers.CrossOver.plist", data: plist(["BottleDir": "/Volumes/Games/Bottles"]))
        XCTAssertEqual(discovery.crossOverBottleDirectory().path, "/Volumes/Games/Bottles")
    }

    func testCustomEngineValidation() throws {
        let tmp = try TemporaryDirectory()
        let loader = try tmp.file("wine-11/bin/wine", data: x86Loader, executable: true)
        let custom = try XCTUnwrap(EngineDiscovery.customEngine(at: loader))
        XCTAssertEqual(custom.kind, .custom)
        XCTAssertNil(EngineDiscovery.customEngine(at: try tmp.file("bin/notwine", data: x86Loader, executable: true)))
    }
}
