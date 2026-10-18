import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A fully resolved program invocation. No shell is involved: the executable is
/// started directly with `arguments` and `environment` passed verbatim, so no
/// value can break quoting or inject commands.
struct WineInvocation: Equatable {
    var executable: URL
    var arguments: [String]
    /// Variables layered over the app's own environment.
    var environment: [String: String]
    var workingDirectory: URL?
    /// Human-readable name for logs and the UI ("Steam", "winecfg", "game.exe").
    var displayName: String
}

struct RunResult: Equatable {
    let exitCode: Int32
    /// The tail of the combined stdout/stderr (at most 64 KB).
    let output: String
    /// The log file, when one was kept.
    let logURL: URL?

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case executableMissing(String)
    case notExecutable(String)
    case workingDirectoryMissing(String)
    case launchFailed(String)
    case timedOut(String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "The Wine engine was not found at \(path). Choose another engine in the bottle settings."
        case .notExecutable(let path):
            return "\(path) is not executable."
        case .workingDirectoryMissing(let path):
            return "The program's folder does not exist: \(path)"
        case .launchFailed(let reason):
            return "Could not start the program: \(reason)"
        case .timedOut(let name, let seconds):
            return "\(name) did not finish within \(seconds) seconds and was stopped."
        }
    }
}

/// Starts processes with their output captured to a log file and their exit
/// status observed, so failures are visible instead of silently lost.
struct ProcessRunner {
    /// Starts a long-running program (a game, Steam, an installer) and returns
    /// immediately. `onExit` is called on a background queue with the exit status.
    @discardableResult
    func start(
        _ invocation: WineInvocation,
        logURL: URL,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Process {
        let (process, handle) = try makeProcess(invocation, logURL: logURL)
        process.terminationHandler = { finished in
            Self.appendFooter(to: logURL, status: finished.terminationStatus)
            onExit?(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        // The child owns a duplicate of the descriptor; release ours.
        try? handle.close()
        return process
    }

    /// Runs a short helper (wineboot, reg, wineserver -k) to completion and
    /// returns its exit status and output. The process is terminated if it
    /// exceeds `timeout`.
    func run(_ invocation: WineInvocation, logURL: URL? = nil, timeout: TimeInterval = 300) async throws -> RunResult {
        let log = logURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("steamxbridge-\(UUID().uuidString).log")
        let (process, handle) = try makeProcess(invocation, logURL: log)
        let timeoutFlag = Flag()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                Self.appendFooter(to: log, status: finished.terminationStatus)
                let output = Self.readTail(of: log, maxBytes: 64 * 1024)
                if logURL == nil { try? FileManager.default.removeItem(at: log) }
                if timeoutFlag.isSet {
                    continuation.resume(throwing: ProcessRunnerError.timedOut(invocation.displayName, seconds: Int(timeout.rounded(.up))))
                } else {
                    continuation.resume(returning: RunResult(
                        exitCode: finished.terminationStatus,
                        output: output,
                        logURL: logURL
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                // terminationHandler never fires for a process that failed to start.
                try? handle.close()
                if logURL == nil { try? FileManager.default.removeItem(at: log) }
                continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                return
            }
            try? handle.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timeoutFlag.set()
                Self.stop(process)
            }
        }
    }

    /// Stops a process and everything it started: SIGTERM to its process group,
    /// then SIGKILL after a grace period if anything is still running.
    /// (Wine helpers spawn children; on Linux, Foundation reports the exit only
    /// after every process holding the child's pipes has exited.)
    static func stop(_ process: Process, gracePeriod: TimeInterval = 3) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Foundation starts children as process-group leaders; only signal the
        // group when that holds, so the app's own group is never hit. Decide
        // once, up front: the leader may exit before its children do.
        let isGroupLeader = getpgid(pid) == pid && pid != getpgrp()
        kill(isGroupLeader ? -pid : pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            if isGroupLeader {
                kill(-pid, SIGKILL) // ESRCH when the whole group is already gone
            } else if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    /// The app's environment minus variables that would redirect or alter the
    /// engine: Wine's own (WINEPREFIX, WINESERVER, ...), CrossOver's (CX_*) and
    /// the dynamic loader's (DYLD_*). Bottles set what they need explicitly.
    static func inheritedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !(key.hasPrefix("WINE") || key.hasPrefix("CX_") || key.hasPrefix("DYLD_"))
        }
    }

    /// Checks everything that can be checked before launching.
    func preflight(_ invocation: WineInvocation) throws {
        let fm = FileManager.default
        let path = invocation.executable.path
        guard fm.fileExists(atPath: path) else { throw ProcessRunnerError.executableMissing(path) }
        guard fm.isExecutableFile(atPath: path) else { throw ProcessRunnerError.notExecutable(path) }
        if let cwd = invocation.workingDirectory {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProcessRunnerError.workingDirectoryMissing(cwd.path)
            }
        }
    }

    private func makeProcess(_ invocation: WineInvocation, logURL: URL) throws -> (Process, FileHandle) {
        try preflight(invocation)
        let fm = FileManager.default
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Owner-only from the moment it exists (logs include the environment),
        // and append-only, so output from processes that outlive the one we
        // started can never overwrite the exit footer.
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw ProcessRunnerError.launchFailed("could not create the log file at \(logURL.path)")
        }
        fchmod(fd, 0o600) // in case the file already existed with wider permissions
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(Data(Self.header(for: invocation).utf8))

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        var environment = Self.inheritedEnvironment(ProcessInfo.processInfo.environment)
        environment.merge(invocation.environment) { _, new in new }
        process.environment = environment
        if let cwd = invocation.workingDirectory { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        return (process, handle)
    }

    static func header(for invocation: WineInvocation) -> String {
        var lines = [
            "# SteamXBridge run log: \(invocation.displayName)",
            "# started: \(ISO8601DateFormatter().string(from: Date()))",
            "# executable: \(invocation.executable.path)",
            "# arguments: \(invocation.arguments.map { "[\($0)]" }.joined(separator: " "))",
            "# working directory: \(invocation.workingDirectory?.path ?? "(inherited)")",
        ]
        for key in invocation.environment.keys.sorted() {
            lines.append("# env \(key)=\(invocation.environment[key] ?? "")")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func appendFooter(to url: URL, status: Int32) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let line = "\n# exited with status \(status) at \(ISO8601DateFormatter().string(from: Date()))\n"
        handle.write(Data(line.utf8))
    }

    static func readTail(of url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        handle.seek(toFileOffset: start)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// A thread-safe one-way flag.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
