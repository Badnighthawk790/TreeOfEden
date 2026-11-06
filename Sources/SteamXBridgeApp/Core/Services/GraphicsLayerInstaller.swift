import Foundation

/// A Direct3D translation layer whose DLLs are copied into plain-Wine
/// prefixes. CrossOver ships and selects its own layers and never needs this.
enum GraphicsLayer: String, Codable {
    /// DXMT: Direct3D 10/11 straight to Metal.
    case dxmt
    /// DXVK: Direct3D 10/11 through Vulkan and MoltenVK.
    case dxvk

    /// The DLLs the layer may contribute; whichever of them the source
    /// folder holds are copied. DXVK-macOS ships only d3d10core and d3d11.
    var dllNames: [String] {
        switch self {
        case .dxmt: return ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"]
        case .dxvk: return ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
        }
    }

    /// DLLs that must stay builtin even though a copy sits in the prefix:
    /// DXMT's `winemetal.dll` only reaches Metal through Wine's unix-call
    /// binding, which works for builtin-loaded modules alone.
    var builtinDLLs: Set<String> {
        self == .dxmt ? ["winemetal.dll"] : []
    }

    /// The WINEDLLOVERRIDES entries for the DLLs this layer installed.
    func overrides(for installed: [String]) -> [String] {
        let native = installed.filter { !builtinDLLs.contains($0) }.map(Self.moduleName).sorted()
        let builtin = installed.filter { builtinDLLs.contains($0) }.map(Self.moduleName).sorted()
        var entries: [String] = []
        if !native.isEmpty { entries.append(native.joined(separator: ",") + "=n,b") }
        if !builtin.isEmpty { entries.append(builtin.joined(separator: ",") + "=b") }
        return entries
    }

    /// "d3d11.dll" -> "d3d11".
    static func moduleName(_ dll: String) -> String {
        dll.lowercased().hasSuffix(".dll") ? String(dll.dropLast(4)) : dll
    }

    /// The DLLs of `layer` found in a source folder's `x64` subfolder.
    func available(in source: URL) -> [String] {
        let x64 = source.appendingPathComponent("x64", isDirectory: true)
        return dllNames.filter { FileManager.default.fileExists(atPath: x64.appendingPathComponent($0).path) }
    }
}

/// Puts a prefix on exactly one graphics layer, or back on Wine's own Direct3D.
///
/// The layer's `x64` DLLs go to system32 and its `x32` DLLs to syswow64 (when
/// the prefix has one). A marker records what was installed and from where,
/// so switching layers first puts back Wine's own copies of the DLLs the old
/// layer replaced: DXMT's dxgi.dll left under DXVK's d3d11.dll would break
/// both. A runtime update (a new source folder) reinstalls the layer.
enum GraphicsLayerInstaller {
    struct Marker: Codable, Equatable {
        var layer: GraphicsLayer
        var source: String
        /// DLL file names installed into system32 (and syswow64 where present).
        var dlls: [String]
    }

    static let markerName = ".steamxbridge-graphics.json"
    /// Written by SteamXBridge 2.0 betas, which only knew DXVK.
    static let legacyDXVKMarkerName = ".steamxbridge-dxvk"

    private static func folders(_ prefix: URL) -> (system32: URL, syswow64: URL) {
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        return (windows.appendingPathComponent("system32", isDirectory: true),
                windows.appendingPathComponent("syswow64", isDirectory: true))
    }

    /// What the prefix currently has installed, if anything.
    static func installed(in prefix: URL) -> Marker? {
        let system32 = folders(prefix).system32
        if let data = try? Data(contentsOf: system32.appendingPathComponent(markerName)),
           let marker = try? JSONDecoder().decode(Marker.self, from: data) {
            return marker
        }
        if let legacy = try? String(contentsOf: system32.appendingPathComponent(legacyDXVKMarkerName), encoding: .utf8) {
            // Lines such as "system32/d3d11.dll".
            let dlls = Set(legacy.split(separator: "\n").compactMap { $0.split(separator: "/").last.map(String.init) })
            return Marker(layer: .dxvk, source: "", dlls: dlls.sorted())
        }
        return nil
    }

    /// Makes `layer` (from `source`) the prefix's layer; nil restores Wine's
    /// own Direct3D. `engineRoot` is the engine folder holding `lib/wine`,
    /// whose builtin DLLs are copied back over a removed layer. Returns the
    /// DLLs now installed. Does nothing when the prefix already matches.
    @discardableResult
    static func apply(_ layer: GraphicsLayer?, from source: URL?, engineRoot: URL, to prefix: URL) throws -> [String] {
        let fm = FileManager.default
        let (system32, syswow64) = folders(prefix)
        let current = installed(in: prefix)
        let wanted: (layer: GraphicsLayer, source: URL)? = layer.flatMap { layer in source.map { (layer, $0) } }

        if let current, let wanted, current.layer == wanted.layer, current.source == wanted.source.path,
           current.dlls.allSatisfy({ fm.fileExists(atPath: system32.appendingPathComponent($0).path) }) {
            return current.dlls
        }
        if current == nil, wanted == nil { return [] }

        var installed: [String] = []
        if let wanted {
            let source = wanted.source
            installed = wanted.layer.available(in: source)
            guard !installed.isEmpty else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.appendingPathComponent("x64").path])
            }
        }
        // Put back what the previous layer replaced and the new one does not.
        if let current {
            for dll in current.dlls where !installed.contains(dll) {
                try restoreBuiltin(dll, engineRoot: engineRoot, system32: system32, syswow64: syswow64)
            }
        }
        if let source = wanted?.source {
            try fm.createDirectory(at: system32, withIntermediateDirectories: true)
            let has32Bit = fm.fileExists(atPath: syswow64.path)
            for dll in installed {
                try replace(system32.appendingPathComponent(dll), with: source.appendingPathComponent("x64/\(dll)"))
                let x32 = source.appendingPathComponent("x32/\(dll)")
                if has32Bit, fm.fileExists(atPath: x32.path) {
                    try replace(syswow64.appendingPathComponent(dll), with: x32)
                }
            }
        }
        try? fm.removeItem(at: system32.appendingPathComponent(legacyDXVKMarkerName))
        let markerURL = system32.appendingPathComponent(markerName)
        if let wanted {
            let marker = Marker(layer: wanted.layer, source: wanted.source.path, dlls: installed)
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        } else {
            try? fm.removeItem(at: markerURL)
        }
        return installed
    }

    /// Copies Wine's own builtin DLL back into the prefix (what wineboot put
    /// there), or removes the file when the engine has none.
    private static func restoreBuiltin(_ dll: String, engineRoot: URL, system32: URL, syswow64: URL) throws {
        let fm = FileManager.default
        let lib = engineRoot.appendingPathComponent("lib/wine", isDirectory: true)
        for (folder, builtins) in [(system32, "x86_64-windows"), (syswow64, "i386-windows")] {
            let target = folder.appendingPathComponent(dll)
            guard fm.fileExists(atPath: target.path) else { continue }
            let original = lib.appendingPathComponent("\(builtins)/\(dll)")
            if fm.fileExists(atPath: original.path) {
                try replace(target, with: original)
            } else {
                try fm.removeItem(at: target)
            }
        }
    }

    /// Replaces a file with a fresh copy (a new file, so a program that has
    /// the old DLL mapped keeps running on it).
    private static func replace(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
    }
}
