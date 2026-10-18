import XCTest
@testable import SteamXBridgeApp

final class ProcessRunnerTests: XCTestCase {
    /// A stand-in for a Wine loader that reports what it was given.
    private func fakeLoader(_ tmp: TemporaryDirectory, exitCode: Int = 0, body: String = "") throws -> URL {
        try tmp.file("engine/bin/wine", contents: """
        #!/bin/sh
        for arg in "$@"; do echo "ARG:[$arg]"; done
        echo "CWD:$(basename "$(pwd -P)")"
        echo "PREFIX:$WINEPREFIX"
        echo "INJECTED:${INJECTED:-unset}"
        \(body)
        exit \(exitCode)
        """, executable: true)
    }

    func testRunPassesArgumentsVerbatimWithoutAShell() async throws {
        let tmp = try TemporaryDirectory()
        let loader = try fakeLoader(tmp, exitCode: 3)
        let gameFolder = try tmp.directory("My Game Folder")
        let log = tmp.url.appendingPathComponent("logs/run.log")
        let hostile = #"a b; echo INJECTED=yes $(touch /tmp/sxb-pwned) 'q'"#

        let result = try await ProcessRunner().run(WineInvocation(
            executable: loader,
            arguments: ["/path with spaces/game.exe", hostile],
            environment: ["WINEPREFIX": "/prefix/with 'quote'"],
            workingDirectory: gameFolder,
            displayName: "game.exe"
        ), logURL: log)

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.output.contains("ARG:[/path with spaces/game.exe]"), result.output)
        XCTAssertTrue(result.output.contains("ARG:[\(hostile)]"), "the hostile string arrives as one literal argument")
        XCTAssertTrue(result.output.contains("INJECTED:unset"))
        XCTAssertTrue(result.output.contains("CWD:My Game Folder"))
        XCTAssertTrue(result.output.contains("PREFIX:/prefix/with 'quote'"))
        XCTAssertTrue(result.output.contains("# exited with status 3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/sxb-pwned"))

        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "logs hold the environment, so they are owner-only")
    }

    func testRunWithoutLogKeepsNoFile() async throws {
        let tmp = try TemporaryDirectory()
        let result = try await ProcessRunner().run(WineInvocation(
            executable: try fakeLoader(tmp), arguments: ["--version"], environment: [:],
            workingDirectory: nil, displayName: "wine"
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.logURL)
        XCTAssertTrue(result.output.contains("ARG:[--version]"))
    }

    func testStartReportsExitStatus() throws {
        let tmp = try TemporaryDirectory()
        let finished = expectation(description: "process exited")
        let status = LockedValue<Int32>(-1)
        try ProcessRunner().start(WineInvocation(
            executable: try fakeLoader(tmp, exitCode: 7), arguments: [], environment: [:],
            workingDirectory: nil, displayName: "game"
        ), logURL: tmp.url.appendingPathComponent("start.log")) { code in
            status.set(code)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(status.get(), 7)
    }

    func testTimeoutStopsTheProcess() async throws {
        let tmp = try TemporaryDirectory()
        // The loader starts a child that outlives it unless the whole group is stopped.
        let loader = try fakeLoader(tmp, body: "sleep 30")
        let started = Date()
        do {
            _ = try await ProcessRunner().run(WineInvocation(
                executable: loader, arguments: [], environment: [:], workingDirectory: nil, displayName: "slow"
            ), timeout: 0.5)
            XCTFail("expected a timeout")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .timedOut("slow", seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout must stop the helper's children too")
    }

    func testInheritedEnvironmentDropsWineCrossOverAndLoaderVariables() {
        let filtered = ProcessRunner.inheritedEnvironment([
            "WINEPREFIX": "/elsewhere", "WINESERVER": "/x", "CX_BOTTLE": "Other", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
            "PATH": "/usr/bin", "HOME": "/Users/me", "LANG": "en_US.UTF-8",
        ])
        XCTAssertEqual(filtered, ["PATH": "/usr/bin", "HOME": "/Users/me", "LANG": "en_US.UTF-8"])
    }

    func testLateOutputFromChildrenIsAppendedAfterTheFooter() throws {
        let tmp = try TemporaryDirectory()
        let loader = try tmp.file("engine/bin/wine", contents: "#!/bin/sh\n(sleep 1; echo LATE-OUTPUT) &\necho EARLY\nexit 0\n", executable: true)
        let log = tmp.url.appendingPathComponent("late.log")
        let exited = expectation(description: "exit")
        try ProcessRunner().start(WineInvocation(executable: loader, arguments: [], environment: [:],
                                                 workingDirectory: nil, displayName: "late"), logURL: log) { _ in exited.fulfill() }
        wait(for: [exited], timeout: 10)
        Thread.sleep(forTimeInterval: 1.5) // let the background child write
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("EARLY"))
        XCTAssertTrue(text.contains("LATE-OUTPUT"))
        XCTAssertTrue(text.contains("# exited with status 0"), "the footer is never overwritten")
    }

    func testPreflightRejectsMissingAndNonExecutableFiles() throws {
        let tmp = try TemporaryDirectory()
        let runner = ProcessRunner()
        func invocation(_ url: URL, cwd: URL? = nil) -> WineInvocation {
            WineInvocation(executable: url, arguments: [], environment: [:], workingDirectory: cwd, displayName: "x")
        }
        XCTAssertThrowsError(try runner.preflight(invocation(tmp.url.appendingPathComponent("nope")))) {
            guard case .executableMissing = $0 as? ProcessRunnerError else { return XCTFail("\($0)") }
        }
        let plain = try tmp.file("plain.txt", contents: "hi")
        XCTAssertThrowsError(try runner.preflight(invocation(plain))) {
            guard case .notExecutable = $0 as? ProcessRunnerError else { return XCTFail("\($0)") }
        }
        let loader = try fakeLoader(tmp)
        XCTAssertThrowsError(try runner.preflight(invocation(loader, cwd: tmp.url.appendingPathComponent("missing")))) {
            guard case .workingDirectoryMissing = $0 as? ProcessRunnerError else { return XCTFail("\($0)") }
        }
    }
}

/// A tiny lock-protected box for values written from background callbacks.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}
