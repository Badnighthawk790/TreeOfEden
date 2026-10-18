import XCTest
@testable import SteamXBridgeApp

final class VDFParserTests: XCTestCase {
    func testParsesNestedObjects() {
        let node = VDFParser.parse("""
        "AppState"
        {
            "appid"  "220"
            "name"   "Half-Life 2"
            "UserConfig" { "language" "english" }
        }
        """)
        XCTAssertEqual(node["AppState"]?["appid"]?.stringValue, "220")
        XCTAssertEqual(node["AppState"]?["UserConfig"]?["language"]?.stringValue, "english")
    }

    func testKeyLookupIsCaseInsensitive() {
        let node = VDFParser.parse(#""LibraryFolders" { "1" "D:\\SteamLibrary" }"#)
        XCTAssertEqual(node["libraryfolders"]?["1"]?.stringValue, #"D:\SteamLibrary"#)
        XCTAssertEqual(node["LIBRARYFOLDERS"]?["1"]?.stringValue, #"D:\SteamLibrary"#)
    }

    func testQuotedBracesAreLiterals() {
        let node = VDFParser.parse(#""root" { "a" "{" "b" "}" "c" "value" }"#)
        XCTAssertEqual(node["root"]?["a"]?.stringValue, "{")
        XCTAssertEqual(node["root"]?["b"]?.stringValue, "}")
        XCTAssertEqual(node["root"]?["c"]?.stringValue, "value")
    }

    func testEscapesCommentsAndConditionals() {
        let node = VDFParser.parse("""
        // header comment
        "root"
        {
            "path"   "C:\\\\Games\\\\Steam" // trailing comment
            "quote"  "say \\"hi\\""
            "only"   "win" [$WIN32]
            "after"  "ok"
        }
        """)
        XCTAssertEqual(node["root"]?["path"]?.stringValue, #"C:\Games\Steam"#)
        XCTAssertEqual(node["root"]?["quote"]?.stringValue, #"say "hi""#)
        XCTAssertEqual(node["root"]?["only"]?.stringValue, "win")
        XCTAssertEqual(node["root"]?["after"]?.stringValue, "ok", "a [$WIN32] conditional must not shift the following pairs")
    }

    func testTruncatedInputDoesNotHang() {
        let node = VDFParser.parse(#""root" { "a" "unterminated"#)
        XCTAssertNotNil(node["root"])
        XCTAssertNil(VDFParser.parse("")["anything"])
    }
}

final class ShellLinkParserTests: XCTestCase {
    func testParsesTargetWorkingDirectoryAndArguments() {
        let data = ShellLinkBuilder.make(
            target: #"C:\Games\Foo\foo.exe"#,
            workingDirectory: #"C:\Games\Foo"#,
            arguments: "-windowed -nosplash"
        )
        let link = ShellLinkParser.parse(data)
        XCTAssertEqual(link?.targetPath, #"C:\Games\Foo\foo.exe"#)
        XCTAssertEqual(link?.workingDirectory, #"C:\Games\Foo"#)
        XCTAssertEqual(link?.arguments, "-windowed -nosplash")
    }

    func testPrefersUnicodeLocalBasePath() {
        let data = ShellLinkBuilder.make(target: #"C:\Spiele\Über\spiel.exe"#, unicodeLinkInfo: true)
        XCTAssertEqual(ShellLinkParser.parse(data)?.targetPath, #"C:\Spiele\Über\spiel.exe"#)
    }

    func testWorksWithoutIDList() {
        let data = ShellLinkBuilder.make(target: #"C:\a.exe"#, includeIDList: false)
        XCTAssertEqual(ShellLinkParser.parse(data)?.targetPath, #"C:\a.exe"#)
    }

    func testRejectsMalformedData() {
        XCTAssertNil(ShellLinkParser.parse(Data()))
        XCTAssertNil(ShellLinkParser.parse(Data(repeating: 0, count: 200)))
        var data = ShellLinkBuilder.make(target: #"C:\a.exe"#)
        data = data.prefix(90) // cut inside LinkInfo
        XCTAssertNil(ShellLinkParser.parse(data))
    }
}

final class MachOInspectorTests: XCTestCase {
    func testThinBinaries() {
        XCTAssertEqual(MachOInspector.inspect(Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])), .machO([.x86_64]))
        XCTAssertEqual(MachOInspector.inspect(Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])), .machO([.arm64]))
    }

    func testUniversalBinary() {
        var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]
        bytes += [0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16)
        bytes += [0x01, 0x00, 0x00, 0x0C] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(MachOInspector.inspect(Data(bytes)), .machO([.x86_64, .arm64]))
    }

    func testScriptsAndOtherFiles() {
        XCTAssertEqual(MachOInspector.inspect(Data("#!/usr/bin/env perl\nprint 1;\n".utf8)), .script(interpreter: "/usr/bin/env"))
        // A Java class file shares the fat magic but has a version number where the slice count would be.
        XCTAssertEqual(MachOInspector.inspect(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34])), .unknown)
        XCTAssertEqual(MachOInspector.inspect(Data([0x4D, 0x5A, 0x90, 0x00])), .unknown) // a Windows PE "MZ"
        XCTAssertEqual(MachOInspector.inspect(Data([0xCF])), .unknown)
    }
}

final class GPUStackTests: XCTestCase {
    func testParsesEveryGenerationAndTier() {
        XCTAssertEqual(GPUStack.parse(brand: "Apple M1").generation, 1)
        XCTAssertEqual(GPUStack.parse(brand: "Apple M2 Pro").generation, 2)
        XCTAssertEqual(GPUStack.parse(brand: "Apple M4 Max").generation, 4)
        XCTAssertEqual(GPUStack.parse(brand: "Apple M5").generation, 5)
        XCTAssertEqual(GPUStack.parse(brand: "Apple M16 Ultra").generation, 16)
    }

    func testUnidentifiedBrands() {
        for brand in ["", "Apple M", "Apple Mx", "Apple M2x", "VirtualApple @ 2.50GHz processor", "Intel(R) Core(TM) i9-9880H"] {
            XCTAssertNil(GPUStack.parse(brand: brand).generation, brand)
        }
        XCTAssertEqual(GPUStack.parse(brand: "").marketingName, "Unknown CPU")
    }

    func testCapabilitiesFollowGeneration() {
        let m2 = GPUStack.parse(brand: "Apple M2")
        XCTAssertFalse(m2.hasHardwareRayTracing)
        XCTAssertFalse(m2.hasDynamicCaching)
        XCTAssertTrue(m2.supportsMetalFX)

        for brand in ["Apple M3", "Apple M4 Pro", "Apple M5 Max"] {
            let chip = GPUStack.parse(brand: brand)
            XCTAssertTrue(chip.hasHardwareRayTracing, brand)
            XCTAssertTrue(chip.hasDynamicCaching, brand)
            XCTAssertTrue(chip.hasHardwareMeshShading, brand)
        }
    }

    func testVirtualMachinesDoNotClaimHardwareFeatures() {
        let vm = GPUStack.parse(brand: "Apple M3 (Virtual)")
        XCTAssertEqual(vm.generation, 3)
        XCTAssertTrue(vm.isVirtualMachine)
        XCTAssertFalse(vm.isIdentified)
        XCTAssertFalse(vm.hasHardwareRayTracing)
    }

    func testFeatureStatusesNeverClaimMissingHardware() {
        let m2 = GPUStack.parse(brand: "Apple M2")
        let rt = m2.featureStatuses.first { $0.feature == "Hardware ray tracing" }
        XCTAssertEqual(rt?.isAvailable, false)
        let unknown = GPUStack.parse(brand: "")
        XCTAssertTrue(unknown.featureStatuses.allSatisfy { !$0.isAvailable })
    }
}

final class WindowsCommandLineTests: XCTestCase {
    func testSplitsLikeCommandLineToArgvW() {
        XCTAssertEqual(WindowsCommandLine.split("-windowed  -dx11"), ["-windowed", "-dx11"])
        XCTAssertEqual(WindowsCommandLine.split(#"-config "C:\My Games\cfg.ini" -x"#), ["-config", #"C:\My Games\cfg.ini"#, "-x"])
        XCTAssertEqual(WindowsCommandLine.split(#"a\\"b c" d"#), [#"a\b c"#, "d"], "2n backslashes + quote -> n backslashes, quote toggles")
        XCTAssertEqual(WindowsCommandLine.split(#"a\\\"b"#), [#"a\"b"#], "2n+1 backslashes + quote -> n backslashes + literal quote")
        XCTAssertEqual(WindowsCommandLine.split(#""say ""hi"" now""#), [#"say "hi" now"#])
        XCTAssertEqual(WindowsCommandLine.split(#"C:\path\to\"#), [#"C:\path\to\"#], "trailing backslashes stay literal")
        XCTAssertEqual(WindowsCommandLine.split(#""""#), [""], "an empty quoted argument is kept")
        XCTAssertEqual(WindowsCommandLine.split("   "), [])
    }
}

final class GameCompatibilityTests: XCTestCase {
    private func crossOver(_ version: String) -> WineEngine {
        WineEngine(kind: .crossOver, name: "CrossOver \(version)", version: version, loaderPath: "/x/wine",
                   wineserverPath: nil, bundlePath: nil, dxvkSourcePath: nil, architectures: [], features: [.d3dMetal])
    }

    func testHelldiversNeedsCrossOver26AndRecommends262() throws {
        let entry = try XCTUnwrap(GameCompatibility.lookup(appID: "553850", name: nil))
        XCTAssertNotNil(GameCompatibility.assessment(of: entry, engine: crossOver("25.1.1")))
        XCTAssertNil(GameCompatibility.assessment(of: entry, engine: crossOver("26.0")))
        XCTAssertNotNil(GameCompatibility.advisory(of: entry, engine: crossOver("26.1.0")))
        XCTAssertNil(GameCompatibility.advisory(of: entry, engine: crossOver("26.3.0")))
        let gptk = WineEngine(kind: .gamePortingToolkit, name: "GPTK", version: "3.0", loaderPath: "/g/wine64",
                              wineserverPath: nil, bundlePath: nil, dxvkSourcePath: nil, architectures: [.x86_64], features: [.d3dMetal])
        XCTAssertTrue(GameCompatibility.assessment(of: entry, engine: gptk)?.contains("create a new CrossOver bottle") == true)
        XCTAssertFalse(entry.note.contains("including online play"), "online play is not promised")
    }

    func testLookupIsExactByAppIDAndNormalizedByName() {
        XCTAssertNil(GameCompatibility.lookup(appID: "394510", name: "HELLDIVERS"), "the 2015 game has a different App ID")
        XCTAssertEqual(GameCompatibility.lookup(appID: nil, name: "HELLDIVERS™ 2")?.appID, "553850")
        XCTAssertNil(GameCompatibility.lookup(appID: nil, name: "Helldivers"))
    }
}
