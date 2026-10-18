import XCTest
@testable import SteamXBridgeApp

final class CrossOverBottleConfigTests: XCTestCase {
    /// Shaped like a real cxbottle.conf written by CrossOver 26.3.
    private let sample = """
    ;; CrossOver bottle configuration
    ;; Do not edit while CrossOver is running

    [Bottle]
    "BottleID" = "6F0B1A7E-0000-4000-8000-000000000001"
    "Version" = "26.3.0.39832"
    "Template" = "win10_64"
    "WineArch" = "win64"

    [ManagedUpdatePolicy]
    "^drive_c/users/crossover/" = "Copy"

    [EnvironmentVariables]
    "CX_GRAPHICS_BACKEND" = "d3dmetal"
    "DXMT_ENABLE_NVEXT" = "0"
    "DXMT_ENABLE_NVEXT"="1"
    WINEMSYNC = 1

    """

    func testReadsQuotedUnquotedAndDuplicateKeys() {
        let config = CrossOverBottleConfig(text: sample)
        XCTAssertEqual(config.value(section: "Bottle", key: "Version"), "26.3.0.39832")
        XCTAssertEqual(config.value(section: "bottle", key: "Template"), "win10_64", "section names are case-insensitive")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND"), "d3dmetal")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "DXMT_ENABLE_NVEXT"), "1", "the last occurrence wins")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "WINEMSYNC"), "1")
        XCTAssertNil(config.value(section: "Bottle", key: "CX_GRAPHICS_BACKEND"), "keys are scoped to their section")
    }

    func testSetReplacesFirstOccurrenceAndDropsDuplicates() {
        var config = CrossOverBottleConfig(text: sample)
        config.setValue("dxmt", section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND")
        config.setValue("0", section: "EnvironmentVariables", key: "DXMT_ENABLE_NVEXT")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND"), "dxmt")
        XCTAssertEqual(config.text.components(separatedBy: "DXMT_ENABLE_NVEXT").count - 1, 1)
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "DXMT_ENABLE_NVEXT"), "0")
        XCTAssertTrue(config.text.hasPrefix(";; CrossOver bottle configuration\n"), "comments are preserved")
        XCTAssertTrue(config.text.contains(#""^drive_c/users/crossover/" = "Copy""#), "unrelated sections are untouched")
    }

    func testAddsNewKeysInsideTheSectionAndRemovesKeys() throws {
        var config = CrossOverBottleConfig(text: sample)
        config.setValue("1", section: "EnvironmentVariables", key: "MTL_HUD_ENABLED")
        config.setValue(nil, section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND")
        let lines = config.lines
        let header = try XCTUnwrap(lines.firstIndex(of: "[EnvironmentVariables]"))
        let hud = try XCTUnwrap(lines.firstIndex(of: #""MTL_HUD_ENABLED" = "1""#))
        XCTAssertGreaterThan(hud, header)
        XCTAssertNil(config.value(section: "EnvironmentVariables", key: "CX_GRAPHICS_BACKEND"), "nil removes the key (CrossOver's Auto)")
    }

    func testCreatesAMissingSectionAndKeepsKeysOutOfOtherSections() {
        var config = CrossOverBottleConfig(text: "[Bottle]\n\"Template\" = \"win10_64\"\n")
        config.setValue("1", section: "EnvironmentVariables", key: "WINEMSYNC")
        XCTAssertEqual(config.value(section: "EnvironmentVariables", key: "WINEMSYNC"), "1")
        XCTAssertNil(config.value(section: "Bottle", key: "WINEMSYNC"))
        XCTAssertTrue(config.text.contains("[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\""))
    }

    func testEscapesQuotesInValues() {
        var config = CrossOverBottleConfig(text: "")
        config.setValue(#"say "hi" \ there"#, section: "EnvironmentVariables", key: "X")
        XCTAssertEqual(CrossOverBottleConfig(text: config.text).value(section: "EnvironmentVariables", key: "X"), #"say "hi" \ there"#)
    }
}
