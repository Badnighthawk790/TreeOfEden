import XCTest
@testable import SteamXBridgeApp

final class WindowsPathMapperTests: XCTestCase {
    func testMapsDrivesThroughDosdevices() throws {
        let tmp = try TemporaryDirectory()
        let prefix = try tmp.directory("prefix")
        try tmp.directory("prefix/drive_c/Games")
        let external = try tmp.directory("external")
        try tmp.symlink("prefix/dosdevices/c:", to: "../drive_c")
        try tmp.symlink("prefix/dosdevices/d:", to: external.path)
        let mapper = WindowsPathMapper(prefix: prefix)

        XCTAssertEqual(canonical(mapper.hostURL(forWindowsPath: #"C:\Program Files (x86)\Steam"#)),
                       canonical(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")))
        XCTAssertEqual(canonical(mapper.hostURL(forWindowsPath: "c:/Games")),
                       canonical(prefix.appendingPathComponent("drive_c/Games")))
        XCTAssertEqual(canonical(mapper.hostURL(forWindowsPath: #"D:\SteamLibrary"#)),
                       canonical(external.appendingPathComponent("SteamLibrary")))
        XCTAssertEqual(canonical(mapper.hostURL(forWindowsPath: #"\\?\C:\Long\Path"#)),
                       canonical(prefix.appendingPathComponent("drive_c/Long/Path")))
        XCTAssertEqual(canonical(mapper.hostURL(forWindowsPath: "C:")),
                       canonical(prefix.appendingPathComponent("drive_c")))
    }

    func testRejectsUnmappablePaths() throws {
        let tmp = try TemporaryDirectory()
        let mapper = WindowsPathMapper(prefix: try tmp.directory("prefix"))
        XCTAssertNil(mapper.hostURL(forWindowsPath: #"E:\NoSuchDrive"#))
        XCTAssertNil(mapper.hostURL(forWindowsPath: #"\\server\share\x"#))
        XCTAssertNil(mapper.hostURL(forWindowsPath: #"relative\path"#))
        XCTAssertNil(mapper.hostURL(forWindowsPath: "C:foo"))
        XCTAssertNil(mapper.hostURL(forWindowsPath: "   "))
    }

    func testFallsBackToDriveCAndPassesPosixPathsThrough() throws {
        let tmp = try TemporaryDirectory()
        let prefix = try tmp.directory("prefix")
        let mapper = WindowsPathMapper(prefix: prefix)
        XCTAssertEqual(mapper.hostURL(forWindowsPath: #"C:\x"#)?.path, prefix.appendingPathComponent("drive_c/x").path)
        XCTAssertEqual(mapper.hostURL(forWindowsPath: "/Users/me/Games")?.path, "/Users/me/Games")
    }

    func testContainment() {
        let root = URL(fileURLWithPath: "/a/b")
        XCTAssertTrue(URL(fileURLWithPath: "/a/b/c").isContained(in: root))
        XCTAssertTrue(URL(fileURLWithPath: "/a/b").isContained(in: root))
        XCTAssertFalse(URL(fileURLWithPath: "/a/bc").isContained(in: root))
        XCTAssertFalse(URL(fileURLWithPath: "/a/b/../x").isContained(in: root))
    }
}

final class SteamLibraryTests: XCTestCase {
    /// A prefix with Windows Steam on C: and a second library on D: (an external folder).
    private func makePrefixWithSteam(_ tmp: TemporaryDirectory) throws -> (prefix: URL, external: URL) {
        let prefix = try tmp.directory("prefix")
        let external = try tmp.directory("external")
        try tmp.symlink("prefix/dosdevices/c:", to: "../drive_c")
        try tmp.symlink("prefix/dosdevices/d:", to: external.path)
        let steam = "prefix/drive_c/Program Files (x86)/Steam"
        try tmp.file("\(steam)/steam.exe")
        try tmp.file("\(steam)/steamapps/libraryfolders.vdf", contents: #"""
        "libraryfolders"
        {
            "0" { "path" "C:\\Program Files (x86)\\Steam" }
            "1" { "path" "D:\\SteamLibrary" }
            "2" { "path" "E:\\Missing" }
        }
        """#)
        try tmp.file("\(steam)/steamapps/appmanifest_220.acf", contents: """
        "AppState" { "appid" "220" "name" "Half-Life 2" "installdir" "Half-Life 2" "StateFlags" "4" "SizeOnDisk" "6500000000" }
        """)
        try tmp.file("\(steam)/steamapps/appmanifest_666.acf", contents: """
        "AppState" { "appid" "666" "name" "Evil" "installdir" "../../../evil" "StateFlags" "4" }
        """)
        try tmp.file("external/SteamLibrary/steamapps/appmanifest_553850.acf", contents: """
        "AppState" { "appid" "553850" "name" "HELLDIVERS™ 2" "installdir" "Helldivers 2" "StateFlags" "6" }
        """)
        return (prefix, external)
    }

    func testFindsGamesInEveryMappedLibrary() throws {
        let tmp = try TemporaryDirectory()
        let (prefix, external) = try makePrefixWithSteam(tmp)
        let install = try XCTUnwrap(SteamInstallation.locate(inPrefix: prefix))
        let reader = SteamLibraryReader(installation: install)

        XCTAssertEqual(reader.libraryRoots().count, 2, "C: and D: libraries; the missing E: library is skipped")
        let apps = reader.installedApps()
        XCTAssertEqual(apps.map(\.appID), ["220", "553850"])
        XCTAssertEqual(canonical(apps[1].installDirectory),
                       canonical(external.appendingPathComponent("SteamLibrary/steamapps/common/Helldivers 2")))
        XCTAssertTrue(apps[0].isFullyInstalled)
        XCTAssertEqual(apps[0].sizeOnDisk, 6_500_000_000)
        XCTAssertFalse(apps.contains { $0.appID == "666" }, "an installdir escaping steamapps/common is rejected")
    }

    func testLegacyLibraryFoldersFormat() {
        let paths = SteamLibraryReader.libraryPaths(fromLibraryFolders: #"""
        "LibraryFolders"
        {
            "TimeNextStatsReport" "1700000000"
            "ContentStatsID" "-123"
            "1" "D:\\SteamLibrary"
            "2" "E:\\Games"
        }
        """#)
        XCTAssertEqual(paths, [#"D:\SteamLibrary"#, #"E:\Games"#])
    }

    func testManifestValidation() {
        let root = URL(fileURLWithPath: "/lib")
        XCTAssertNil(SteamLibraryReader.parseManifest(#""AppState" { "appid" "1" "installdir" "" }"#, libraryRoot: root))
        XCTAssertNil(SteamLibraryReader.parseManifest(#""AppState" { "appid" "abc" "installdir" "x" }"#, libraryRoot: root))
        XCTAssertNil(SteamLibraryReader.parseManifest(#""AppState" { "appid" "1" "installdir" "." }"#, libraryRoot: root))
        let app = SteamLibraryReader.parseManifest(#""AppState" { "appid" "7" "installdir" "Game" }"#, libraryRoot: root)
        XCTAssertEqual(app?.name, "App 7")
        XCTAssertEqual(app?.installDirectory.path, "/lib/steamapps/common/Game")
    }

    func testNoSteamInPrefix() throws {
        let tmp = try TemporaryDirectory()
        XCTAssertNil(SteamInstallation.locate(inPrefix: try tmp.directory("prefix")))
    }
}

final class ExecutableFinderTests: XCTestCase {
    func testPrefersTheGameOverRedistributablesAndHelpers() throws {
        let tmp = try TemporaryDirectory()
        let game = try tmp.directory("Half-Life 2")
        try tmp.file("Half-Life 2/hl2.exe", contents: String(repeating: "x", count: 10))
        try tmp.file("Half-Life 2/_CommonRedist/vcredist/vc_redist.x64.exe", contents: String(repeating: "x", count: 5000))
        try tmp.file("Half-Life 2/_CommonRedist/DotNet/ndp48-x86-x64-allos-enu.exe", contents: String(repeating: "x", count: 9000))
        try tmp.file("Half-Life 2/UnityCrashHandler64.exe", contents: String(repeating: "x", count: 4000))
        try tmp.file("Half-Life 2/bin/tools.exe", contents: String(repeating: "x", count: 3000))

        let candidates = ExecutableFinder.candidates(in: game, preferredName: "hl2")
        XCTAssertEqual(candidates.first?.lastPathComponent, "hl2.exe")
        XCTAssertFalse(candidates.contains { $0.path.contains("_CommonRedist") })
        XCTAssertFalse(candidates.contains { $0.lastPathComponent.hasPrefix("UnityCrashHandler") })
    }

    func testFallsBackToShallowestThenLargest() throws {
        let tmp = try TemporaryDirectory()
        let game = try tmp.directory("Game")
        try tmp.file("Game/small.exe", contents: "x")
        try tmp.file("Game/big.exe", contents: String(repeating: "x", count: 100))
        try tmp.file("Game/deep/deeper.exe", contents: String(repeating: "x", count: 1000))
        XCTAssertEqual(ExecutableFinder.candidates(in: game).map(\.lastPathComponent), ["big.exe", "small.exe", "deeper.exe"])
    }
}

final class ProgramDiscoveryTests: XCTestCase {
    func testListsStartMenuProgramsAndSkipsUninstallers() throws {
        let tmp = try TemporaryDirectory()
        let prefix = try tmp.directory("prefix")
        try tmp.symlink("prefix/dosdevices/c:", to: "../drive_c")
        try tmp.file("prefix/drive_c/Games/Foo/foo.exe")
        let menu = "prefix/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Foo"
        try tmp.file("\(menu)/Foo.lnk", data: ShellLinkBuilder.make(
            target: #"C:\Games\Foo\foo.exe"#, workingDirectory: #"C:\Games\Foo"#, arguments: "-dx11"))
        try tmp.file("\(menu)/Uninstall Foo.lnk", data: ShellLinkBuilder.make(target: #"C:\Games\Foo\unins000.exe"#))
        try tmp.file("\(menu)/Foo Website.lnk", data: ShellLinkBuilder.make(target: #"C:\Games\Foo\site.url"#))
        let userMenu = "prefix/drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"
        try tmp.file("\(userMenu)/Foo Again.lnk", data: ShellLinkBuilder.make(target: #"C:\Games\Foo\foo.exe"#))
        try tmp.file("\(userMenu)/Bar.lnk", data: ShellLinkBuilder.make(target: #"C:\Games\Bar\bar.exe"#))

        let programs = ProgramDiscovery(prefix: prefix).programs()
        XCTAssertEqual(programs.map(\.name), ["Bar", "Foo"], "uninstallers, links to non-programs and duplicate targets are dropped")
        let foo = try XCTUnwrap(programs.last)
        XCTAssertEqual(canonical(foo.target), canonical(prefix.appendingPathComponent("drive_c/Games/Foo/foo.exe")))
        XCTAssertEqual(foo.arguments, "-dx11")
        XCTAssertEqual(canonical(foo.workingDirectory), canonical(prefix.appendingPathComponent("drive_c/Games/Foo")))
    }
}

final class ExternalBottleFinderTests: XCTestCase {
    func testFindsCrossOverWhiskyAndWinePrefixes() throws {
        let tmp = try TemporaryDirectory()
        let home = tmp.url
        try tmp.file("Library/Application Support/CrossOver/Bottles/Steam/system.reg")
        try tmp.file("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        try tmp.directory("Library/Application Support/CrossOver/Bottles/NotABottle")

        let whisky = "Library/Containers/com.isaacmarovitz.Whisky"
        try tmp.directory("\(whisky)/Bottles/1111-2222/drive_c")
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["info": ["name": "My Games"]], format: .xml, options: 0)
        try tmp.file("\(whisky)/Bottles/1111-2222/Metadata.plist", data: metadata)
        let custom = try tmp.directory("Elsewhere/WhiskyBottle/drive_c").deletingLastPathComponent()
        let tracked = try PropertyListSerialization.data(
            fromPropertyList: ["paths": [["relative": custom.absoluteString]], "fileVersion": ["major": 1]],
            format: .xml, options: 0)
        try tmp.file("\(whisky)/BottleVM.plist", data: tracked)
        try tmp.file(".wine/system.reg")

        let found = ExternalBottleFinder(home: home).discover()
        XCTAssertEqual(found.map(\.source), ["CrossOver", "Whisky", "Whisky", "Wine prefix"])
        XCTAssertEqual(found[1].engineHint, "com.isaacmarovitz.Whisky", "the engine that made the bottle is remembered")
        XCTAssertEqual(found.first?.name, "Steam")
        XCTAssertEqual(found.first?.hasSteam, true)
        XCTAssertEqual(found[1].name, "My Games")
        XCTAssertEqual(canonical(found[2].prefix), canonical(custom))
        XCTAssertEqual(found[3].name, "Default Wine prefix")
    }
}

final class BottleStoreTests: XCTestCase {
    func testCreateLoadRenameAndRemoveOwnedBottle() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        var bottle = try store.createBottle(named: "  Steam Games!  ") { $0.windowsVersion = .win11 }
        XCTAssertEqual(bottle.name, "Steam Games!")
        XCTAssertTrue(bottle.prefixURL.lastPathComponent.hasPrefix("steam-games-"))
        XCTAssertTrue(bottle.prefixURL.isContained(in: store.prefixesDirectory))

        bottle.name = "Renamed"
        bottle.settings.graphics = .dxmt
        try store.save(bottle)
        let loaded = store.loadBottles()
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.bottles.map(\.name), ["Renamed"])
        XCTAssertEqual(loaded.bottles.first?.windowsVersion, .win11)
        XCTAssertEqual(loaded.bottles.first?.settings.graphics, .dxmt)
        XCTAssertEqual(loaded.bottles.first?.prefixPath, bottle.prefixPath, "renaming never moves the prefix")

        try store.remove(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bottle.prefixPath))
        XCTAssertEqual(store.loadBottles().bottles.count, 0)
    }

    func testLinkingNeverDeletesTheExternalPrefix() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url.appendingPathComponent("store"), deletesToTrash: false)
        let external = try tmp.directory("CrossOver/Bottles/Steam")
        try tmp.directory("CrossOver/Bottles/Steam/drive_c")

        let linked = try store.linkBottle(prefix: external, named: "Steam", source: "CrossOver", existing: [])
        XCTAssertEqual(linked.origin, .linked)
        XCTAssertThrowsError(try store.linkBottle(prefix: external, named: "Again", source: nil, existing: [linked])) {
            XCTAssertEqual($0 as? BottleStoreError, .alreadyLinked("Steam"))
        }
        try store.remove(linked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testRejectsNonPrefixesAndBlankNames() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        XCTAssertThrowsError(try store.linkBottle(prefix: try tmp.directory("empty"), named: "X", source: nil, existing: []))
        XCTAssertThrowsError(try store.createBottle(named: " \n "))
    }

    func testDuplicateCopiesThePrefixIntoANewOwnedBottle() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        let original = try store.createBottle(named: "Original")
        try FileManager.default.createDirectory(at: original.driveC, withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: original.driveC.appendingPathComponent("save.dat"))

        let copy = try store.duplicate(original, named: "Copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.origin, .owned)
        XCTAssertEqual(try String(contentsOf: copy.driveC.appendingPathComponent("save.dat"), encoding: .utf8), "progress")
        XCTAssertEqual(store.loadBottles().bottles.count, 2)
    }

    func testDuplicateRebasesPinsAndRefusesCrossOverBottles() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        var original = try store.createBottle(named: "Original")
        original.pinnedPrograms = [
            PinnedProgram(name: "Game", path: original.driveC.appendingPathComponent("Games/game.exe").path),
            PinnedProgram(name: "Elsewhere", path: "/Volumes/Games/tool.exe"),
        ]
        try store.save(original)
        let copy = try store.duplicate(original, named: "Copy")
        XCTAssertTrue(copy.pinnedPrograms[0].path.hasPrefix(copy.prefixPath + "/"), "pins inside the prefix follow the copy")
        XCTAssertEqual(copy.pinnedPrograms[1].path, "/Volumes/Games/tool.exe")
        XCTAssertNotEqual(copy.pinnedPrograms[0].id, original.pinnedPrograms[0].id)

        let crossOver = try tmp.directory("CrossOver/Bottles/Steam/drive_c").deletingLastPathComponent()
        try tmp.file("CrossOver/Bottles/Steam/cxbottle.conf", contents: "[Bottle]\n")
        let linked = try store.linkBottle(prefix: crossOver, named: "Steam", source: "CrossOver", existing: [])
        XCTAssertThrowsError(try store.duplicate(linked, named: "Copy 2")) {
            XCTAssertEqual($0 as? BottleStoreError, .crossOverBottleNeedsCrossOver)
        }
    }

    func testFailedSaveLeavesNoOrphanedPrefix() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        try tmp.file("Bottles", contents: "a file where the metadata folder should be")
        XCTAssertThrowsError(try store.createBottle(named: "Broken"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.prefixesDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRemoveRefusesUnsafeOwnedPaths() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url.appendingPathComponent("store"), deletesToTrash: false)
        try FileManager.default.createDirectory(at: store.prefixesDirectory, withIntermediateDirectories: true)
        let precious = try tmp.directory("precious")
        try tmp.file("precious/data.txt", contents: "keep me")

        // The Prefixes folder itself, a symlink inside it, and a path escaping it.
        let link = store.prefixesDirectory.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        for path in [store.prefixesDirectory.path, link.path, store.prefixesDirectory.path + "/../../precious"] {
            var tampered = Bottle(name: "T", prefixPath: path, origin: .owned)
            tampered.id = UUID()
            try store.save(tampered)
            try store.remove(tampered)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.appendingPathComponent("data.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.prefixesDirectory.path))
    }

    func testLinkingTheSamePrefixThroughASymlinkIsDetected() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url.appendingPathComponent("store"), deletesToTrash: false)
        let prefix = try tmp.directory("prefix/drive_c").deletingLastPathComponent()
        let linked = try store.linkBottle(prefix: prefix, named: "A", source: nil, existing: [])
        let alias = try tmp.symlink("alias", to: prefix.path)
        XCTAssertThrowsError(try store.linkBottle(prefix: alias, named: "B", source: nil, existing: [linked]))
    }

    func testCorruptAndMinimalMetadata() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        try tmp.file("Bottles/broken.json", contents: "{ not json")
        try tmp.file("Bottles/minimal.json", contents: """
        {"id": "A8F9E2C8-6D07-467C-863F-98D64A37CB33", "name": "Old", "prefixPath": "/tmp/old",
         "settings": {"graphics": "someFutureBackend", "metalHUD": true}}
        """)
        let loaded = store.loadBottles()
        XCTAssertEqual(loaded.problems.count, 1)
        let old = try XCTUnwrap(loaded.bottles.first)
        XCTAssertEqual(old.windowsVersion, .win10)
        XCTAssertEqual(old.settings.graphics, .automatic, "an unknown backend falls back to the default")
        XCTAssertTrue(old.settings.metalHUD)
        XCTAssertTrue(old.settings.msync)
    }

    func testSlugs() {
        XCTAssertEqual(BottleStore.slug("Steam Games!"), "steam-games")
        XCTAssertEqual(BottleStore.slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(BottleStore.slug("日本語"), "bottle")
        XCTAssertEqual(BottleStore.slug(""), "bottle")
    }

    func testLogTitles() {
        XCTAssertEqual(BottleStore.logTitle(for: URL(fileURLWithPath: "/l/2026-10-18T14-03-22-steam-client-1a2b.log")),
                       "steam-client · 2026-10-18 14:03:22")
        XCTAssertEqual(BottleStore.logTitle(for: URL(fileURLWithPath: "/l/2026-10-18T14-03-22-game-exe-1a2b.wine.log")),
                       "game-exe (Wine) · 2026-10-18 14:03:22")
        XCTAssertEqual(BottleStore.logTitle(for: URL(fileURLWithPath: "/l/odd.log")), "odd")
    }

    func testLogLocations() throws {
        let tmp = try TemporaryDirectory()
        let store = BottleStore(root: tmp.url, deletesToTrash: false)
        let bottle = Bottle(name: "B", prefixPath: "/tmp/b")
        let url = store.logURL(for: bottle, program: "Steam Client", at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(url.isContained(in: store.logsDirectory))
        XCTAssertTrue(url.lastPathComponent.contains("-steam-client-"))
        XCTAssertEqual(url.pathExtension, "log")
        XCTAssertNotEqual(url, store.logURL(for: bottle, program: "Steam Client", at: Date(timeIntervalSince1970: 0)),
                          "runs started in the same second get distinct logs")
    }
}

final class DXVKInstallerTests: XCTestCase {
    func testCopiesOnlyDXVKDLLsIntoTheRightFolders() throws {
        let tmp = try TemporaryDirectory()
        let source = try tmp.directory("DXVK")
        try tmp.file("DXVK/x64/d3d11.dll", contents: "x64-d3d11")
        try tmp.file("DXVK/x64/README.txt", contents: "not a dll")   // must be skipped, not stop the copy
        try tmp.file("DXVK/x64/dxgi.dll", contents: "x64-dxgi")
        try tmp.file("DXVK/x32/d3d11.dll", contents: "x32-d3d11")
        let prefix = try tmp.directory("prefix")
        try tmp.file("prefix/drive_c/windows/system32/d3d11.dll", contents: "wine builtin stub")

        XCTAssertFalse(DXVKInstaller.isInstalled(in: prefix))
        let installed = try DXVKInstaller.install(from: source, into: prefix)
        XCTAssertEqual(installed, ["system32/d3d11.dll", "system32/dxgi.dll", "syswow64/d3d11.dll"])
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll"), encoding: .utf8), "x64-d3d11")
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("drive_c/windows/syswow64/d3d11.dll"), encoding: .utf8), "x32-d3d11")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/README.txt").path))
        XCTAssertTrue(DXVKInstaller.isInstalled(in: prefix))
    }

    func testFailsWhenTheSourceHasNoDLLs() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("Empty/x64/notes.txt")
        XCTAssertThrowsError(try DXVKInstaller.install(from: tmp.url.appendingPathComponent("Empty"), into: try tmp.directory("prefix")))
    }
}
