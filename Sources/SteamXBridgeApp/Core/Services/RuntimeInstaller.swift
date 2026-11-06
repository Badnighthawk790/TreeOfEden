import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// The built-in runtime once installed: a folder holding Wine and the
/// graphics layers, described by the manifest it was made from.
struct InstalledRuntime: Equatable {
    let location: URL
    let manifest: RuntimeManifest

    static let engineID = "builtIn:steamxbridge"

    /// The runtime as an engine. Its ID does not change between runtime
    /// versions, so bottles keep using the built-in engine after an update.
    var engine: WineEngine {
        var engine = WineEngine(
            kind: .builtIn,
            name: manifest.displayName,
            version: manifest.wineVersion,
            loaderPath: location.appendingPathComponent(manifest.loaderPath).path,
            wineserverPath: location.appendingPathComponent(manifest.wineserverPath).path,
            bundlePath: nil,
            dxvkSourcePath: manifest.dxvkPath.map { location.appendingPathComponent($0).path },
            architectures: manifest.needsRosetta ? [.x86_64] : [.arm64],
            features: manifest.features,
            dxmtSourcePath: manifest.dxmtPath.map { location.appendingPathComponent($0).path }
        )
        engine.id = Self.engineID
        return engine
    }
}

/// Installs the runtime bundled inside the app into Application Support.
///
/// Each archive is checked against the SHA-256 in the manifest before anything
/// is unpacked; everything is unpacked into a staging folder that only becomes
/// the runtime, by one rename, once it is complete. A half-finished install
/// (the app quit, the disk filled up) is therefore never mistaken for a
/// working engine, and the next launch simply starts over.
struct RuntimeInstaller {
    /// The bundle's `Runtime` folder (manifest plus archives); nil when this
    /// build does not include a runtime (`swift run`).
    let source: URL?
    /// Where runtimes are installed, one folder per manifest ID.
    let root: URL

    static let markerName = ".installed.json"

    init(source: URL?, root: URL = RuntimeInstaller.defaultRoot()) {
        self.source = source
        self.root = root
    }

    static func defaultRoot() -> URL {
        BottleStore.defaultRoot().appendingPathComponent("Runtime", isDirectory: true)
    }

    /// The Runtime folder inside the running app, if it has one.
    static func bundledSource(in bundle: Bundle = .main) -> URL? {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Runtime", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(RuntimeManifest.fileName).path)
        else { return nil }
        return folder
    }

    func manifest() throws -> RuntimeManifest {
        guard let source else { throw RuntimeError.notBundled }
        let url = source.appendingPathComponent(RuntimeManifest.fileName)
        guard let data = try? Data(contentsOf: url) else { throw RuntimeError.notBundled }
        let manifest: RuntimeManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        } catch {
            throw RuntimeError.invalidManifest("unreadable \(RuntimeManifest.fileName)")
        }
        try manifest.validate()
        return manifest
    }

    /// The installed runtime for `manifest`, if a complete install of exactly
    /// that manifest exists.
    func installed(_ manifest: RuntimeManifest) -> InstalledRuntime? {
        let location = root.appendingPathComponent(manifest.id, isDirectory: true)
        guard let data = try? Data(contentsOf: location.appendingPathComponent(Self.markerName)),
              let recorded = try? JSONDecoder().decode(RuntimeManifest.self, from: data), recorded == manifest,
              FileManager.default.isExecutableFile(atPath: location.appendingPathComponent(manifest.loaderPath).path)
        else { return nil }
        return InstalledRuntime(location: location, manifest: manifest)
    }

    /// Verifies and unpacks every component, then makes the result the
    /// runtime for this manifest. `progress` receives short status lines.
    @discardableResult
    func install(_ manifest: RuntimeManifest, progress: (String) -> Void = { _ in }) throws -> InstalledRuntime {
        guard let source else { throw RuntimeError.notBundled }
        try manifest.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        removeLeftovers()

        for component in manifest.components {
            let archive = source.appendingPathComponent(component.archive)
            guard let size = (try? fm.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber else {
                throw RuntimeError.archiveMissing(component.archive)
            }
            progress("Checking \(component.name) \(component.version)…")
            guard size.int64Value == component.size, try Self.sha256(of: archive) == component.sha256 else {
                throw RuntimeError.checksumMismatch(component.archive)
            }
        }
        try checkFreeSpace(for: manifest)

        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for component in manifest.components {
                progress("Unpacking \(component.name) \(component.version)…")
                let destination = staging.appendingPathComponent(component.destination, isDirectory: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try unpack(source.appendingPathComponent(component.archive), into: destination,
                           stripComponents: component.stripComponents, member: component.member, name: component.name)
            }
            for copy in manifest.copies {
                let from = staging.appendingPathComponent(copy.from)
                let to = staging.appendingPathComponent(copy.to)
                guard fm.fileExists(atPath: from.path) else { throw RuntimeError.incomplete(copy.from) }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
            for path in [manifest.loaderPath, manifest.wineserverPath] + [manifest.dxmtPath, manifest.dxvkPath].compactMap({ $0 })
            where !fm.fileExists(atPath: staging.appendingPathComponent(path).path) {
                throw RuntimeError.incomplete(path)
            }
            guard fm.isExecutableFile(atPath: staging.appendingPathComponent(manifest.loaderPath).path) else {
                throw RuntimeError.incomplete(manifest.loaderPath)
            }
            progress("Finishing…")
            // The archives were verified above; their contents inherit the
            // download's quarantine flag, which would stop Wine from starting.
            Self.removeQuarantine(under: staging)
            let marker = try JSONEncoder().encode(manifest)
            try marker.write(to: staging.appendingPathComponent(Self.markerName), options: .atomic)

            let location = root.appendingPathComponent(manifest.id, isDirectory: true)
            if fm.fileExists(atPath: location.path) {
                // An older, incomplete or damaged install of the same ID.
                let old = root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
                try fm.moveItem(at: location, to: old)
                try? fm.removeItem(at: old)
            }
            try fm.moveItem(at: staging, to: location)
            pruneOlderRuntimes(keeping: manifest.id)
            return InstalledRuntime(location: location, manifest: manifest)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// The installed runtime, installing it first when needed.
    func prepare(progress: (String) -> Void = { _ in }) throws -> InstalledRuntime {
        let manifest = try manifest()
        if let installed = installed(manifest) { return installed }
        return try install(manifest, progress: progress)
    }

    // MARK: Steps

    private func unpack(_ archive: URL, into destination: URL, stripComponents: Int, member: String?, name: String) throws {
        guard let tar = ["/usr/bin/tar", "/bin/tar"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RuntimeError.unpackFailed(name, status: -1, output: "tar was not found")
        }
        // No -P: tar refuses absolute paths and `..` members, so nothing lands
        // outside the destination.
        var arguments = ["-x", "-f", archive.path, "-C", destination.path]
        if stripComponents > 0 { arguments.append("--strip-components=\(stripComponents)") }
        if let member { arguments += ["--", member] }
        let result = try Self.run(URL(fileURLWithPath: tar), arguments)
        guard result.status == 0 else { throw RuntimeError.unpackFailed(name, status: result.status, output: result.output) }
    }

    private func checkFreeSpace(for manifest: RuntimeManifest) throws {
        // Unpacked Wine is roughly four times its compressed size.
        let needed = manifest.components.reduce(Int64(0)) { $0 + $1.size } * 4
        #if os(macOS)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw RuntimeError.notEnoughSpace(needed: needed, available: available)
        }
        #endif
    }

    /// Staging folders of an install that never finished.
    private func removeLeftovers() {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(".staging-") || item.lastPathComponent.hasPrefix(".old-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Keeps the new runtime and the most recent older one (a game started
    /// before the update may still be running from it); removes the rest.
    private func pruneOlderRuntimes(keeping current: String) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let older = items
            .filter { $0.lastPathComponent != current && !$0.lastPathComponent.hasPrefix(".") }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(Self.markerName).path) }
            .sorted { modified($0) > modified($1) }
        for runtime in older.dropFirst() { try? fm.removeItem(at: runtime) }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.appendingPathComponent(Self.markerName).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    // MARK: Helpers

    /// Lower-case hex SHA-256 of a file, read in chunks.
    static func sha256(of file: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        // Linux (the test suite): coreutils.
        let result = try run(URL(fileURLWithPath: "/usr/bin/sha256sum"), [file.path])
        guard result.status == 0, let hash = result.output.split(separator: " ").first else {
            throw RuntimeError.checksumMismatch(file.lastPathComponent)
        }
        return String(hash)
        #endif
    }

    /// Removes macOS's quarantine flag from every file in a folder (never
    /// following symbolic links). Does nothing on other systems.
    static func removeQuarantine(under folder: URL) {
        #if canImport(Darwin)
        let paths = [folder.path] + (FileManager.default.enumerator(atPath: folder.path)?.compactMap {
            ($0 as? String).map { folder.appendingPathComponent($0).path }
        } ?? [])
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
        #endif
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
