#if os(macOS)
import Foundation

struct BackgroundAgentService {
    private let label = "com.stemnet.steamxbridge.agent"

    func install(intervalSeconds: Int) throws {
        let fm = FileManager.default
        let launchAgentsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let supportDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SteamXBridge", isDirectory: true)

        try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let scriptURL = supportDir.appendingPathComponent("agent.sh")
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

        let script = """
        #!/bin/zsh
        set -euo pipefail

        REQUEST_FILE="$HOME/Library/Application Support/SteamXBridge/launch-request.sh"

        if [[ -f "$REQUEST_FILE" ]]; then
          /usr/bin/nice -n 20 /bin/zsh "$REQUEST_FILE"
          rm -f "$REQUEST_FILE"
        fi
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/zsh</string>
            <string>\(scriptURL.path)</string>
          </array>
          <key>StartInterval</key>
          <integer>\(max(20, intervalSeconds))</integer>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Background</string>
        </dict>
        </plist>
        """

        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        _ = try runLaunchCtl("unload", plistURL.path, allowFailure: true)
        _ = try runLaunchCtl("load", plistURL.path, allowFailure: false)
    }

    func uninstall() throws {
        let fm = FileManager.default
        let plistURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")

        if fm.fileExists(atPath: plistURL.path) {
            _ = try runLaunchCtl("unload", plistURL.path, allowFailure: true)
            try fm.removeItem(at: plistURL)
        }
    }

    private func runLaunchCtl(_ command: String, _ path: String, allowFailure: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [command, path]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            throw NSError(domain: "BackgroundAgentService", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "launchctl \(command) failed"])
        }

        return process.terminationStatus
    }
}
#endif
