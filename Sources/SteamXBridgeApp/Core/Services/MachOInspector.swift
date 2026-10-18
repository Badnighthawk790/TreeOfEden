import Foundation

/// A CPU architecture slice found in a Mach-O binary.
enum CPUArchitecture: Hashable, Codable, CustomStringConvertible {
    case x86_64
    case arm64
    case i386
    case arm
    case other(Int32)

    init(cpuType: Int32) {
        switch cpuType {
        case 0x0100_0007: self = .x86_64
        case 0x0100_000C: self = .arm64
        case 7: self = .i386
        case 12: self = .arm
        default: self = .other(cpuType)
        }
    }

    var description: String {
        switch self {
        case .x86_64: return "x86_64"
        case .arm64: return "arm64"
        case .i386: return "i386"
        case .arm: return "arm"
        case .other(let type): return "cpu(\(type))"
        }
    }
}

/// What kind of executable a file is, determined from its first bytes only —
/// the file is never executed.
enum ExecutableKind: Equatable {
    /// A thin or universal Mach-O binary with these architecture slices.
    case machO([CPUArchitecture])
    /// A `#!` script; `interpreter` is the first token of the shebang line.
    case script(interpreter: String)
    case unknown
}

enum MachOInspector {
    /// Inspects a file on disk. Returns `.unknown` if it cannot be read.
    static func inspect(_ url: URL) -> ExecutableKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        // Fat headers hold at most a handful of 20/32-byte entries; 4 KiB is plenty.
        let data = handle.readData(ofLength: 4096)
        return inspect(data)
    }

    /// Inspects the leading bytes of an executable.
    static func inspect(_ data: Data) -> ExecutableKind {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .unknown }

        if bytes[0] == 0x23, bytes[1] == 0x21 { // "#!"
            let line = bytes.dropFirst(2).prefix { $0 != 0x0A && $0 != 0x0D }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let interpreter = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return .script(interpreter: interpreter)
        }

        let magicBE = readUInt32BE(bytes, 0)
        let magicLE = readUInt32LE(bytes, 0)

        // Thin binaries are little-endian on every Apple platform.
        if magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE {
            guard bytes.count >= 8 else { return .unknown }
            return .machO([CPUArchitecture(cpuType: Int32(bitPattern: readUInt32LE(bytes, 4)))])
        }

        // Universal ("fat") headers are big-endian. 0xCAFEBABE is also the Java
        // class-file magic, so require a plausible slice count.
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            guard bytes.count >= 8 else { return .unknown }
            let count = Int(readUInt32BE(bytes, 4))
            guard count > 0, count <= 16 else { return .unknown }
            let entrySize = magicBE == 0xCAFE_BABF ? 32 : 20
            var slices: [CPUArchitecture] = []
            for index in 0..<count {
                let offset = 8 + index * entrySize
                guard offset + 4 <= bytes.count else { return .unknown }
                slices.append(CPUArchitecture(cpuType: Int32(bitPattern: readUInt32BE(bytes, offset))))
            }
            return .machO(slices)
        }

        return .unknown
    }

    private static func readUInt32BE(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readUInt32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
