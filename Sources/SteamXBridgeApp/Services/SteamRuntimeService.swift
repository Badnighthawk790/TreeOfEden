import Foundation

enum LaunchError: LocalizedError {
    case invalidProfile
    case unsupportedRuntime

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "The profile is incomplete. Add a name and executable path."
        case .unsupportedRuntime:
            return "Install Whisky or CrossOver and set the runtime binary path."
        }
    }
}

struct SteamRuntimeService {
    func launch(profile: LaunchProfile, runtimeBinary: String, gpu: GPUStack = .detect()) throws {
        guard profile.isValid else { throw LaunchError.invalidProfile }
        guard !runtimeBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaunchError.unsupportedRuntime
        }

        let launchScript = generateLaunchScript(profile: profile, runtimeBinary: runtimeBinary, gpu: gpu)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steamxbridge-\(profile.id.uuidString).command")

        try launchScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Owner-only: the rendered script embeds the resolved environment, which may
        // include values the user placed in customEnv. Keep it off other accounts.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    func generateLaunchScript(profile: LaunchProfile, runtimeBinary: String, gpu: GPUStack = .detect()) -> String {
        let envExports = profile.launchEnvironment(gpu: gpu)
            .sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\($0.value.shellEscaped)" }
            .joined(separator: "\n")

        // Resolve HOME in Swift: the value is shell-escaped below, so a literal
        // "$HOME" would not expand and would create a directory named "$HOME".
        let defaultPrefixRoot = NSHomeDirectory() + "/.steamxbridge/prefixes"
        let winePrefix = profile.winePrefixPath.isEmpty
            ? "\(defaultPrefixRoot)/\(profile.name.replacingOccurrences(of: " ", with: "_"))"
            : profile.winePrefixPath

        return """
        #!/bin/zsh
        set -e

        export WINEPREFIX=\(winePrefix.shellEscaped)
        mkdir -p "$WINEPREFIX"

        \(envExports)

        arch -x86_64 \(runtimeBinary.shellEscaped) \(profile.gameExecutablePath.shellEscaped)
        """
    }
}

private extension String {
    var shellEscaped: String {
        if isEmpty { return "''" }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
