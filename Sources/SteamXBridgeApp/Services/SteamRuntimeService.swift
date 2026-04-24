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
    func launch(profile: LaunchProfile, runtimeBinary: String) throws {
        guard profile.isValid else { throw LaunchError.invalidProfile }
        guard !runtimeBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaunchError.unsupportedRuntime
        }

        let launchScript = generateLaunchScript(profile: profile, runtimeBinary: runtimeBinary)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steamxbridge-\(profile.id.uuidString).command")

        try launchScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    func generateLaunchScript(profile: LaunchProfile, runtimeBinary: String) -> String {
        let envExports = profile.launchEnvironment
            .sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\($0.value.shellEscaped)" }
            .joined(separator: "\n")

        let winePrefix = profile.protonPrefixPath.isEmpty
            ? "$HOME/.steamxbridge/prefixes/\(profile.name.replacingOccurrences(of: " ", with: "_"))"
            : profile.protonPrefixPath

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
