import XCTest
@testable import SteamXBridgeApp

/// The bundled runtime: fake Wine and DXMT archives built with tar, installed
/// the way the app installs the real ones.
final class RuntimeInstallerTests: XCTestCase {
    private func tar(_ folder: URL, name: String, into output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar")
        process.arguments = ["-c", "-z", "-f", output.path, "-C", folder.path, name]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func size(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A Runtime folder like the one packaging puts in the app bundle.
    private func makeSource(_ tmp: TemporaryDirectory, id: String = "wine-11.0-test",
                            loader: String = "wine/bin/wine") throws -> (URL, RuntimeManifest) {
        let wine = "build/Wine Devel.app/Contents/Resources/wine"
        try tmp.file("\(wine)/bin/wine", contents: "#!/bin/sh\nexit 0\n", executable: true)
        try tmp.file("\(wine)/bin/wineserver", contents: "#!/bin/sh\nexit 0\n", executable: true)
        try tmp.directory("\(wine)/lib/wine/x86_64-unix")
        try tmp.file("build/Wine Devel.app/Contents/Resources/start/bin/winehelp", contents: "not needed")
        try tmp.file("build/dxmt-v0.80/x86_64-windows/d3d11.dll", contents: "MZ dxmt d3d11")
        try tmp.file("build/dxmt-v0.80/x86_64-unix/winemetal.so", contents: "winemetal")
        let source = try tmp.directory("Runtime")
        let build = tmp.url.appendingPathComponent("build")
        try tar(build, name: "Wine Devel.app", into: source.appendingPathComponent("wine.tar.gz"))
        try tar(build, name: "dxmt-v0.80", into: source.appendingPathComponent("dxmt.tar.gz"))

        func component(_ name: String, _ archive: String, _ destination: String, strip: Int = 1,
                       member: String? = nil) throws -> RuntimeManifest.Component {
            let url = source.appendingPathComponent(archive)
            return RuntimeManifest.Component(name: name, version: "1", archive: archive,
                                             sha256: try RuntimeInstaller.sha256(of: url), size: try size(url),
                                             destination: destination, stripComponents: strip, member: member,
                                             license: "LGPL-2.1-or-later", url: "https://example.invalid/\(archive)",
                                             sourceURL: "https://example.invalid/src/\(archive)")
        }
        let manifest = RuntimeManifest(
            id: id, displayName: "Built-in engine (Wine 11.0)", wineVersion: "11.0",
            components: [try component("Wine", "wine.tar.gz", "wine", strip: 4, member: "Wine Devel.app/Contents/Resources/wine"),
                         try component("DXMT", "dxmt.tar.gz", "dxmt")],
            copies: [.init(from: "dxmt/x86_64-unix/winemetal.so", to: "wine/lib/wine/x86_64-unix/winemetal.so")],
            loaderPath: loader, wineserverPath: "wine/bin/wineserver",
            dxmtPath: "dxmt", dxvkPath: nil,
            features: [.dxmt, .wineD3D], needsRosetta: true)
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent(RuntimeManifest.fileName))
        return (source, manifest)
    }

    private func leftovers(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    func testSHA256MatchesAKnownVector() throws {
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("abc.txt", contents: "abc")
        XCTAssertEqual(try RuntimeInstaller.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testInstallsTheBundledRuntimeOnceAndDescribesItsEngine() throws {
        let tmp = try TemporaryDirectory()
        let (source, manifest) = try makeSource(tmp)
        let installer = RuntimeInstaller(source: source, root: tmp.url.appendingPathComponent("installed"))
        var messages: [String] = []
        let runtime = try installer.prepare { messages.append($0) }
        XCTAssertEqual(runtime.manifest, manifest)
        XCTAssertTrue(messages.contains("Unpacking Wine 1…"), "\(messages)")
        let wineLib = runtime.location.appendingPathComponent("wine/lib/wine/x86_64-unix/winemetal.so")
        XCTAssertEqual(try String(contentsOf: wineLib, encoding: .utf8), "winemetal", "DXMT's unix side is placed inside Wine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.location.appendingPathComponent("dxmt/x86_64-windows/d3d11.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.location.appendingPathComponent("wine/bin/winehelp").path),
                       "only the engine folder of the Wine archive is unpacked")
        XCTAssertEqual(leftovers(in: installer.root), [], "no staging folders left")

        let engine = runtime.engine
        XCTAssertEqual(engine.kind, .builtIn)
        XCTAssertEqual(engine.id, InstalledRuntime.engineID, "the ID survives runtime updates")
        XCTAssertEqual(engine.loaderPath, runtime.location.appendingPathComponent("wine/bin/wine").path)
        XCTAssertEqual(engine.dxmtSourcePath, runtime.location.appendingPathComponent("dxmt").path)
        XCTAssertTrue(engine.needsRosetta)
        XCTAssertFalse(engine.isCrossOver)

        // A second launch finds it installed and leaves it alone.
        let sentinel = runtime.location.appendingPathComponent("sentinel")
        try Data().write(to: sentinel)
        XCTAssertEqual(try installer.prepare(), runtime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testATamperedArchiveIsNotInstalled() throws {
        let tmp = try TemporaryDirectory()
        let (source, manifest) = try makeSource(tmp)
        var tampered = manifest
        tampered.components[1].sha256 = String(repeating: "0", count: 64)
        let installer = RuntimeInstaller(source: source, root: tmp.url.appendingPathComponent("installed"))
        XCTAssertThrowsError(try installer.install(tampered)) { error in
            XCTAssertEqual(error as? RuntimeError, .checksumMismatch("dxmt.tar.gz"))
        }
        XCTAssertNil(installer.installed(tampered))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: installer.root.path)) ?? [], [])
    }

    func testAnIncompleteRuntimeIsRolledBack() throws {
        let tmp = try TemporaryDirectory()
        let (source, manifest) = try makeSource(tmp, loader: "wine/bin/wine64")
        let installer = RuntimeInstaller(source: source, root: tmp.url.appendingPathComponent("installed"))
        XCTAssertThrowsError(try installer.install(manifest)) { error in
            XCTAssertEqual(error as? RuntimeError, .incomplete("wine/bin/wine64"))
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: installer.root.path)) ?? [], [],
                       "the staging folder is removed")
    }

    func testADamagedInstallIsReplaced() throws {
        let tmp = try TemporaryDirectory()
        let (source, manifest) = try makeSource(tmp)
        let root = tmp.url.appendingPathComponent("installed")
        // Same ID, but no marker: an install from a crashed launch or a manual edit.
        try tmp.file("installed/\(manifest.id)/wine/bin/wine", contents: "broken", executable: true)
        let installer = RuntimeInstaller(source: source, root: root)
        XCTAssertNil(installer.installed(manifest))
        let runtime = try installer.prepare()
        XCTAssertEqual(try String(contentsOf: runtime.location.appendingPathComponent("wine/bin/wine"), encoding: .utf8),
                       "#!/bin/sh\nexit 0\n")
    }

    func testKeepsOnlyTheNewestOlderRuntime() throws {
        let tmp = try TemporaryDirectory()
        let root = tmp.url.appendingPathComponent("installed")
        for (index, id) in ["runtime-a", "runtime-b", "runtime-c"].enumerated() {
            let sourceTmp = try TemporaryDirectory()
            let (source, manifest) = try makeSource(sourceTmp, id: id)
            try RuntimeInstaller(source: source, root: root).install(manifest)
            // Distinct, increasing marker dates regardless of filesystem resolution.
            let marker = root.appendingPathComponent("\(id)/\(RuntimeInstaller.markerName)")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 * (index + 1)))],
                                                  ofItemAtPath: marker.path)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(kept, ["runtime-b", "runtime-c"], "a game may still run from the previous runtime")
    }

    func testRejectsManifestsThatCouldWriteOutsideTheRuntime() throws {
        let tmp = try TemporaryDirectory()
        let (source, manifest) = try makeSource(tmp)
        let installer = RuntimeInstaller(source: source, root: tmp.url.appendingPathComponent("installed"))
        var escaping = manifest
        escaping.components[0].destination = "../outside"
        XCTAssertThrowsError(try installer.install(escaping))
        var absolute = manifest
        absolute.copies = [.init(from: "dxmt/x86_64-unix/winemetal.so", to: "/tmp/winemetal.so")]
        XCTAssertThrowsError(try installer.install(absolute))
        var archivePath = manifest
        archivePath.components[0].archive = "../wine.tar.gz"
        XCTAssertThrowsError(try archivePath.validate())
        var option = manifest
        option.components[0].member = "--to-command=sh"
        XCTAssertThrowsError(try option.validate())
        var badID = manifest
        badID.id = ".hidden"
        XCTAssertThrowsError(try badID.validate())
        XCTAssertNoThrow(try manifest.validate())
    }

    func testTheShippedManifestIsValidAndCredited() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("runtime/\(RuntimeManifest.fileName)"))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertTrue(manifest.components.allSatisfy { $0.url.hasPrefix("https://") })
        XCTAssertEqual(manifest.loaderPath, "engine/Wine/bin/wine", "Wine 11 has no wine64 loader to rely on")
        XCTAssertTrue(manifest.features.contains(.dxmt))
        XCTAssertFalse(manifest.features.contains(.d3dMetal), "Apple's D3DMetal is never bundled")
        let notices = try String(contentsOf: repo.appendingPathComponent("runtime/THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        for component in manifest.components {
            XCTAssertTrue(notices.contains(component.sha256), "\(component.archive) is listed in the notices")
        }
        let licenses = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("runtime/licenses").path)
        for text in ["LGPL-2.1-or-later.txt", "LGPL-3.0-or-later.txt", "GPL-3.0-or-later.txt", "Apache-2.0.txt", "MPL-2.0.txt", "DXMT-MIT.txt"] {
            XCTAssertTrue(licenses.contains(text), text)
        }
    }

    /// Installs the real bundled runtime when SXB_RUNTIME_SOURCE points at a
    /// staged Runtime folder (CI sets it to the packaged app's). Skipped otherwise.
    func testInstallsTheRealRuntime() throws {
        guard let path = ProcessInfo.processInfo.environment["SXB_RUNTIME_SOURCE"], !path.isEmpty else {
            throw XCTSkip("SXB_RUNTIME_SOURCE is not set")
        }
        let tmp = try TemporaryDirectory()
        let installer = RuntimeInstaller(source: URL(fileURLWithPath: path, isDirectory: true),
                                         root: tmp.url.appendingPathComponent("Runtime"))
        let runtime = try installer.prepare()
        let engine = runtime.engine
        XCTAssertEqual(MachOInspector.inspect(engine.loaderURL), .machO([.x86_64]))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(engine.wineserverPath)))
        let dxmt = URL(fileURLWithPath: try XCTUnwrap(engine.dxmtSourcePath))
        XCTAssertEqual(GraphicsLayer.dxmt.available(in: dxmt), ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"])
        XCTAssertTrue(EngineDiscovery.hasDXMT(payload: dxmt, engineRoot: engine.rootURL), "winemetal.so sits in the engine")
        XCTAssertFalse(GraphicsLayer.dxvk.available(in: URL(fileURLWithPath: try XCTUnwrap(engine.dxvkSourcePath))).isEmpty)

        // DXMT goes into a prefix, and leaving it restores Wine's own DLLs.
        let prefix = try tmp.directory("prefix")
        let system32 = try tmp.directory("prefix/drive_c/windows/system32")
        try GraphicsLayerInstaller.apply(.dxmt, from: dxmt, engineRoot: engine.rootURL, to: prefix)
        try GraphicsLayerInstaller.apply(nil, from: nil, engineRoot: engine.rootURL, to: prefix)
        let wineDXGI = engine.rootURL.appendingPathComponent("lib/wine/x86_64-windows/dxgi.dll")
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("dxgi.dll")), try Data(contentsOf: wineDXGI))
    }

    func testABuildWithoutARuntimeSaysSo() {
        let installer = RuntimeInstaller(source: nil, root: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertThrowsError(try installer.prepare()) { XCTAssertEqual($0 as? RuntimeError, .notBundled) }
    }
}
