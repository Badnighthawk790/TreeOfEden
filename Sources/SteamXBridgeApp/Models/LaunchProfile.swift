import Foundation

struct LaunchProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var steamAppID: String
    var gameExecutablePath: String
    var protonPrefixPath: String
    var useDXVK: Bool
    var useAsyncShaders: Bool
    var esync: Bool
    var fsync: Bool
    var frameLimit: Int
    var lowResourceMode: Bool
    var customEnv: String

    init(
        id: UUID = UUID(),
        name: String = "",
        steamAppID: String = "",
        gameExecutablePath: String = "",
        protonPrefixPath: String = "",
        useDXVK: Bool = true,
        useAsyncShaders: Bool = true,
        esync: Bool = true,
        fsync: Bool = true,
        frameLimit: Int = 60,
        lowResourceMode: Bool = true,
        customEnv: String = ""
    ) {
        self.id = id
        self.name = name
        self.steamAppID = steamAppID
        self.gameExecutablePath = gameExecutablePath
        self.protonPrefixPath = protonPrefixPath
        self.useDXVK = useDXVK
        self.useAsyncShaders = useAsyncShaders
        self.esync = esync
        self.fsync = fsync
        self.frameLimit = frameLimit
        self.lowResourceMode = lowResourceMode
        self.customEnv = customEnv
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!gameExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
         !steamAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var launchEnvironment: [String: String] {
        var env: [String: String] = [
            "DXVK_HUD": "0",
            "DXVK_ASYNC": useAsyncShaders ? "1" : "0",
            "DXVK_STATE_CACHE": "1",
            "WINEESYNC": esync ? "1" : "0",
            "WINEFSYNC": fsync ? "1" : "0",
            "MESA_GL_VERSION_OVERRIDE": "4.6",
            "MTL_HUD_ENABLED": "0"
        ]

        env["PROTON_USE_WINED3D"] = useDXVK ? "0" : "1"
        env["DXVK_FRAME_RATE"] = "\(lowResourceMode ? min(frameLimit, 60) : frameLimit)"

        if lowResourceMode {
            env["WINEDEBUG"] = "-all"
            env["DXVK_LOG_LEVEL"] = "none"
            env["MALLOC_NANO_ZONE"] = "1"
        }

        for line in customEnv.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2,
               !parts[0].isEmpty,
               !parts[1].isEmpty {
                env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        return env
    }
}
