import XCTest
@testable import SteamXBridgeApp

/// Runs the real built-in engine end to end, the way the app does: install the
/// runtime, create a bottle, run a Windows console program, then a Direct3D 11
/// program on each graphics layer. It needs macOS, Rosetta 2 and the packaged
/// runtime, so it only runs when CI sets SXB_ENGINE_SMOKE=1 and
/// SXB_RUNTIME_SOURCE (see .github/workflows/build-macos.yml).
final class EngineSmokeTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    func testBuiltInEngineRunsWindowsProgramsAndDirect3D() async throws {
        guard environment["SXB_ENGINE_SMOKE"] == "1", let source = environment["SXB_RUNTIME_SOURCE"], !source.isEmpty else {
            throw XCTSkip("SXB_ENGINE_SMOKE is not set")
        }
        let tmp = try TemporaryDirectory()
        let runtime = try RuntimeInstaller(source: URL(fileURLWithPath: source, isDirectory: true),
                                           root: tmp.url.appendingPathComponent("Runtime")).prepare()
        let engine = runtime.engine
        if engine.needsRosetta { XCTAssertTrue(Rosetta.isInstalled, "the engine needs Rosetta 2 on this machine") }

        let store = BottleStore(root: tmp.url.appendingPathComponent("store"), deletesToTrash: false)
        let ops = BottleOperations(store: store, gpu: GPUStack.detect(),
                                   crossOverBottleDirectory: tmp.url.appendingPathComponent("CrossOver"))
        print("smoke: engine \(engine.name) at \(engine.loaderPath) on \(GPUStack.detect().marketingName)")

        // 1. A new bottle: wineboot --init through the app's own launch plan.
        let started = Date()
        var bottle = try await ops.createPlainBottle(named: "Smoke", engine: engine, windowsVersion: .win10,
                                                     settings: BottleSettings())
        print(String(format: "smoke: bottle created in %.0f s", Date().timeIntervalSince(started)))
        XCTAssertTrue(bottle.isInitialized)

        // 2. A console program.
        let ver = try await ops.runner.run(try ops.planner(for: bottle, engine: engine)
            .helper(["cmd", "/c", "ver"], displayName: "ver"), timeout: 300)
        print("smoke: ver -> status \(ver.exitCode)\n\(ver.output)")
        XCTAssertTrue(ver.succeeded)
        XCTAssertTrue(ver.output.contains("Microsoft Windows"), "cmd printed the Windows version")

        // 3. Direct3D 11 on each layer the engine offers.
        guard let probePath = environment["SXB_D3D11_PROBE"], !probePath.isEmpty else {
            print("smoke: SXB_D3D11_PROBE is not set; skipping Direct3D")
            return
        }
        // Inside the bottle, as a game would be.
        let probe = bottle.driveC.appendingPathComponent("d3d11probe.exe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: probePath), to: probe)
        let requireRendering = environment["SXB_REQUIRE_RENDERING"] == "1"

        for graphics in engine.graphicsBackends {
            bottle.settings.graphics = graphics
            try ops.syncGraphicsLayer(bottle: bottle, engine: engine)
            let layer = engine.layer(for: graphics)?.layer
            XCTAssertEqual(GraphicsLayerInstaller.installed(in: bottle.prefixURL)?.layer, layer)
            let invocation = try ops.planner(for: bottle, engine: engine)
                .invocation(for: .program(probe, arguments: [], workingDirectory: nil))
            let result = try await ops.runner.run(invocation, timeout: 300)
            print("smoke: Direct3D 11 with \(graphics.rawValue) (\(layer.map(\.rawValue) ?? "wine's own")) -> status \(result.exitCode)\n\(result.output)")
            XCTAssertTrue(result.output.contains("probe: D3D11CreateDevice"), "the probe ran under \(graphics.rawValue)")
            // The layer the bottle is set to is the one Windows actually loaded.
            switch layer {
            case .dxmt:
                XCTAssertTrue(result.output.contains("winemetal=loaded"), "DXMT served Direct3D 11")
                XCTAssertTrue(result.output.contains("wined3d=absent"), "Wine's own Direct3D stayed out of the way")
            case .dxvk:
                XCTAssertTrue(result.output.contains("winemetal=absent"), "DXMT is not mixed into a DXVK bottle")
            case nil:
                XCTAssertTrue(result.output.contains("winemetal=absent"), "Wine's own Direct3D is back")
            }
            if requireRendering, layer == .dxmt {
                XCTAssertEqual(result.exitCode, 0, "DXMT rendered and read back a frame")
            }
        }
        // Stop the bottle's wineserver so the runner is left clean.
        try? await ops.forceQuit(bottle, engine: engine)
    }
}
