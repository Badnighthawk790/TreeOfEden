import XCTest
@testable import SteamXBridgeApp

/// End-to-end bottle operations against fake engines: shell scripts that behave
/// like a Wine loader (wineboot creates the prefix, the Steam installer creates
/// steam.exe) and like CrossOver's cxbottle.
final class BottleOperationsTests: XCTestCase {
    private func fakeWine(_ tmp: TemporaryDirectory, failWineboot: Bool = false) throws -> WineEngine {
        let loader = try tmp.file("engine/bin/wine", contents: """
        #!/bin/sh
        echo "FAKEWINE $*"
        case "$1" in
          wineboot) \(failWineboot ? "exit 1" : #"mkdir -p "$WINEPREFIX/drive_c/windows/system32"; : > "$WINEPREFIX/system.reg""#) ;;
        esac
        case "$*" in
          *SteamSetup.exe*/S*)
            mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam"
            : > "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe" ;;
        esac
        exit 0
        """, executable: true)
        return WineEngine(kind: .custom, name: "Fake Wine", version: "11.0", loaderPath: loader.path,
                          wineserverPath: nil, bundlePath: nil, dxvkSourcePath: nil,
                          architectures: [.arm64], features: [.d3dMetal, .msync, .esync])
    }

    private func fakeCrossOver(_ tmp: TemporaryDirectory, bottles: URL) throws -> WineEngine {
        let bin = "CrossOver.app/Contents/SharedSupport/CrossOver/bin"
        let wrapper = try tmp.file("\(bin)/wine", contents: "#!/bin/sh\necho \"FAKECX $*\"\nexit 0\n", executable: true)
        try tmp.file("\(bin)/cxbottle", contents: """
        #!/bin/sh
        name=""; template=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --bottle) name="$2"; shift ;;
            --template) template="$2"; shift ;;
          esac
          shift
        done
        dir="\(bottles.path)/$name"
        mkdir -p "$dir/drive_c"
        : > "$dir/system.reg"
        printf ';; CrossOver bottle\\n[Bottle]\\n"Template" = "%s"\\n' "$template" > "$dir/cxbottle.conf"
        exit 0
        """, executable: true)
        return WineEngine(kind: .crossOver, name: "CrossOver 26.3.0", version: "26.3.0", loaderPath: wrapper.path,
                          wineserverPath: nil, bundlePath: nil, dxvkSourcePath: nil, architectures: [],
                          features: [.d3dMetal, .dxmt, .dxvk, .wineD3D, .msync, .dlssMetalFX])
    }

    private func operations(_ tmp: TemporaryDirectory, bottles: URL? = nil) throws -> BottleOperations {
        let crossOverBottles = try bottles ?? tmp.directory("CrossOverBottles")
        return BottleOperations(store: BottleStore(root: try tmp.directory("store"), deletesToTrash: false),
                                gpu: GPUStack.parse(brand: "Apple M2"),
                                crossOverBottleDirectory: crossOverBottles)
    }

    func testCreatesAndInitializesAPlainBottle() async throws {
        let tmp = try TemporaryDirectory()
        let ops = try operations(tmp)
        let bottle = try await ops.createPlainBottle(named: "Games", engine: try fakeWine(tmp),
                                                     windowsVersion: .win11, settings: BottleSettings())
        XCTAssertTrue(bottle.isInitialized)
        let logs = ops.store.logs(for: bottle)
        let text = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("FAKEWINE wineboot --init"))
        XCTAssertTrue(text.contains("FAKEWINE winecfg /v win11"))
        XCTAssertEqual(ops.store.loadBottles().bottles.map(\.name), ["Games"])
    }

    func testFailedInitializationLeavesNoBottleBehind() async throws {
        let tmp = try TemporaryDirectory()
        let ops = try operations(tmp)
        do {
            _ = try await ops.createPlainBottle(named: "Broken", engine: try fakeWine(tmp, failWineboot: true),
                                               windowsVersion: .win10, settings: BottleSettings())
            XCTFail("expected an initialization failure")
        } catch let error as BottleOperationError {
            guard case .initializationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(ops.store.loadBottles().bottles.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: ops.store.prefixesDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the half-created prefix is removed")
    }

    func testCreatesACrossOverBottleAndWritesItsSettings() async throws {
        let tmp = try TemporaryDirectory()
        let bottles = try tmp.directory("CrossOverBottles")
        let ops = try operations(tmp, bottles: bottles)
        var settings = BottleSettings()
        settings.graphics = .d3dMetal
        settings.msync = false
        settings.dlssMetalFX = true

        let bottle = try await ops.createCrossOverBottle(named: "Helldivers/2", engine: try fakeCrossOver(tmp, bottles: bottles),
                                                         windowsVersion: .win10, settings: settings, existing: [])
        XCTAssertEqual(bottle.name, "Helldivers-2")
        XCTAssertTrue(bottle.isCrossOverBottle)
        XCTAssertEqual(bottle.origin, .linked)
        let config = try XCTUnwrap(CrossOverBottleConfig(contentsOf: bottle.prefixURL.appendingPathComponent("cxbottle.conf")))
        XCTAssertEqual(config.value(section: "Bottle", key: "Template"), "win10_64")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND"), "d3dmetal")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "D3DM_ENABLE_METALFX"), "1")
        XCTAssertNil(config.value(section: "EnvironmentVariables", key: "WINEMSYNC"))
        XCTAssertTrue(config.text.hasPrefix(";; CrossOver bottle"), "CrossOver's own lines are kept")
    }

    func testInstallsSteamFromADownloadedInstaller() async throws {
        let tmp = try TemporaryDirectory()
        var ops = try operations(tmp)
        let engine = try fakeWine(tmp)
        let bottle = try await ops.createPlainBottle(named: "Steam", engine: engine, windowsVersion: .win10, settings: BottleSettings())
        let downloads = LockedValue(0)
        ops.download = { _, destination in
            downloads.set(downloads.get() + 1)
            try Data([0x4D, 0x5A, 0x90, 0x00]).write(to: destination)
        }
        let steam = try await ops.installSteam(in: bottle, engine: engine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: steam.steamExecutable.path))
        _ = try await ops.steamInstaller()
        XCTAssertEqual(downloads.get(), 1, "the installer is cached")
    }

    func testRejectsADownloadThatIsNotAnInstaller() async throws {
        let tmp = try TemporaryDirectory()
        var ops = try operations(tmp)
        ops.download = { _, destination in try Data("<html>error</html>".utf8).write(to: destination) }
        do {
            _ = try await ops.steamInstaller()
            XCTFail("expected a download failure")
        } catch let error as BottleOperationError {
            guard case .downloadFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ops.store.downloadsDirectory.appendingPathComponent("SteamSetup.exe").path))
    }

    func testLaunchLogsTheRunAndReportsTheExitStatus() async throws {
        let tmp = try TemporaryDirectory()
        let ops = try operations(tmp)
        let engine = try fakeWine(tmp)
        let bottle = try await ops.createPlainBottle(named: "Run", engine: engine, windowsVersion: .win10, settings: BottleSettings())
        let exe = try tmp.file("store/game/game.exe")

        let exited = expectation(description: "exit")
        let status = LockedValue<Int32>(-1)
        let running = try ops.launch(.program(exe, arguments: ["-x"], workingDirectory: nil), in: bottle, engine: engine) { code in
            status.set(code)
            exited.fulfill()
        }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(status.get(), 0)
        let log = try String(contentsOf: running.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("FAKEWINE \(exe.path) -x"), log)
        XCTAssertTrue(log.contains("# env WINEPREFIX=\(bottle.prefixPath)"))
    }

    func testCrossOverBottleNamesAndTemplates() throws {
        XCTAssertEqual(try BottleOperations.crossOverBottleName("..Steam: Main/2"), "Steam- Main-2")
        XCTAssertThrowsError(try BottleOperations.crossOverBottleName("..."))
        XCTAssertEqual(BottleOperations.crossOverTemplate(for: .win11), "win11_64")
        XCTAssertEqual(BottleOperations.crossOverTemplate(for: .win81), "win10_64")
    }
}
