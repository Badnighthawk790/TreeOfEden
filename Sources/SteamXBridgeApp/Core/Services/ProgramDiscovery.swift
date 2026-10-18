import Foundation

/// A Windows program installed in a bottle, found through its Start Menu shortcut.
struct InstalledProgram: Identifiable, Equatable, Hashable {
    let name: String
    /// The .lnk file itself.
    let shortcut: URL
    /// Host path of the shortcut's target executable, when it could be resolved.
    let target: URL?
    let arguments: String?
    /// Host path of the shortcut's working directory, when set.
    let workingDirectory: URL?

    var id: String { shortcut.path }
}

/// Lists programs in a bottle by reading the Start Menu shortcuts installers
/// create, as CrossOver's Programs view does.
struct ProgramDiscovery {
    let prefix: URL

    /// Start Menu folders: the all-users menu and each user's personal menu
    /// (Wine names the user after the macOS account; CrossOver uses "crossover").
    func startMenuFolders() -> [URL] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var folders = [driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true)]
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        for user in names.sorted() where user != "Public" {
            folders.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs", isDirectory: true))
        }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func programs() -> [InstalledProgram] {
        let mapper = WindowsPathMapper(prefix: prefix)
        var programs: [InstalledProgram] = []
        var seenTargets = Set<String>()

        for folder in startMenuFolders() {
            for shortcut in shortcuts(in: folder) {
                let name = shortcut.deletingPathExtension().lastPathComponent
                guard !Self.isNoise(name: name) else { continue }
                let link = ShellLinkParser.parse(contentsOf: shortcut)
                let target = link?.targetPath.flatMap { mapper.hostURL(forWindowsPath: $0) }
                if let target {
                    let ext = target.pathExtension.lowercased()
                    // Shortcuts to documents, web pages and help files are not programs.
                    guard ["exe", "bat", "cmd", "msi", "lnk"].contains(ext),
                          !Self.isNoise(name: target.deletingPathExtension().lastPathComponent),
                          seenTargets.insert(target.canonicalPath).inserted else { continue }
                }
                programs.append(InstalledProgram(
                    name: name,
                    shortcut: shortcut,
                    target: target,
                    arguments: link?.arguments.flatMap { $0.isEmpty ? nil : $0 },
                    workingDirectory: link?.workingDirectory.flatMap { mapper.hostURL(forWindowsPath: $0) }
                ))
            }
        }
        return programs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// .lnk files under a Start Menu folder, at most four levels deep.
    private func shortcuts(in folder: URL) -> [URL] {
        let lnks = DirectoryWalker.files(under: folder, maxDepth: 4, maxEntries: 5_000)
            .map(\.url)
            .filter { $0.pathExtension.lowercased() == "lnk" }
        return Array(lnks.prefix(500))
    }

    /// Uninstallers, readmes and support links that clutter Start Menus.
    static func isNoise(name: String) -> Bool {
        let lower = name.lowercased()
        let fragments = ["uninstall", "unins0", "readme", "read me", "help", "manual", "website",
                         "release notes", "license", "support", "documentation", "eula"]
        return fragments.contains { lower.contains($0) }
    }
}
