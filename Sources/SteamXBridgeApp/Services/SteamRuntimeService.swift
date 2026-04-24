import Foundation

enum LaunchError: LocalizedError {
    case invalidProfile
    case unsupportedRuntime

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "The profile is incomplete. Add a name and either a Steam App ID or executable path."
        case .unsupportedRuntime:
            return "Install Whisky or CrossOver and set the runtime binary path."
        }
    }
}

struct SteamRuntimeService {
    func launch(profile: LaunchProfile, runtimeBinary: String) throws {
        guard profile.isValid else { throw LaunchError.invalidProfile }

        if shouldLaunchWithSteamURL(profile) {
            try launchSteamAppID(profile.steamAppID)
            return
        }

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

    func queueBackgroundLaunch(profile: LaunchProfile, runtimeBinary: String) throws {
        guard profile.isValid else { throw LaunchError.invalidProfile }

        let command: String
        if shouldLaunchWithSteamURL(profile) {
            command = "open steam://rungameid/\(profile.steamAppID.shellEscapedURL)"
        } else {
            guard !runtimeBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LaunchError.unsupportedRuntime
            }
            command = generateLaunchCommand(profile: profile, runtimeBinary: runtimeBinary)
        }

        let requestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SteamXBridge/launch-request.sh")

        try FileManager.default.createDirectory(
            at: requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let content = """
        #!/bin/zsh
        set -e
        \(command)
        """
        try content.write(to: requestURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: requestURL.path)
    }

    func generateLaunchScript(profile: LaunchProfile, runtimeBinary: String) -> String {
        """
        #!/bin/zsh
        set -e

        \(generateLaunchCommand(profile: profile, runtimeBinary: runtimeBinary))
        """
    }

    func generateLaunchCommand(profile: LaunchProfile, runtimeBinary: String) -> String {
        let envExports = profile.launchEnvironment
            .sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\($0.value.shellEscaped)" }
            .joined(separator: "\n")

        let winePrefix = profile.protonPrefixPath.isEmpty
            ? "$HOME/.steamxbridge/prefixes/\(profile.name.replacingOccurrences(of: " ", with: "_"))"
            : profile.protonPrefixPath

        let nicePrefix = profile.lowResourceMode ? "nice -n 15 " : ""

        return """
        export WINEPREFIX=\(winePrefix.shellEscaped)
        mkdir -p "$WINEPREFIX"

        \(envExports)

        \(nicePrefix)arch -x86_64 \(runtimeBinary.shellEscaped) \(profile.gameExecutablePath.shellEscaped)
        """
    }

    private func shouldLaunchWithSteamURL(_ profile: LaunchProfile) -> Bool {
        !profile.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        profile.gameExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launchSteamAppID(_ appID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["steam://rungameid/\(appID)"]
        try process.run()
    }
}

private extension String {
    var shellEscaped: String {
        if isEmpty { return "''" }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var shellEscapedURL: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
