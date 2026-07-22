import Foundation

public enum MachOParser {
    private enum Endian {
        case little
        case big
    }

    private static let mhMagic: UInt32 = 0xfeedface
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf

    private static let lcLoadDylib: UInt32 = 0x0c
    private static let lcIDDylib: UInt32 = 0x0d
    private static let lcLoadWeakDylib: UInt32 = 0x80000018
    private static let lcReexportDylib: UInt32 = 0x8000001f
    private static let lcLazyLoadDylib: UInt32 = 0x20
    private static let lcLoadUpwardDylib: UInt32 = 0x80000023
    private static let lcCodeSignature: UInt32 = 0x1d
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2c

    public static func parse(data: Data) throws -> MachOSummary {
        guard data.count >= 4 else { throw ParseError.truncated }
        let magicBig = try readUInt32(data, at: 0, endian: .big)

        if magicBig == fatMagic || magicBig == fatMagic64 {
            return try parseFat(data: data, is64Bit: magicBig == fatMagic64)
        }

        return MachOSummary(slices: [try parseSlice(data: data, offset: 0, limit: data.count)])
    }

    public static func looksLikeMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let big = try? readUInt32(data, at: 0, endian: .big)
        let little = try? readUInt32(data, at: 0, endian: .little)
        return big == fatMagic || big == fatMagic64 ||
            little == mhMagic || little == mhMagic64 ||
            big == mhMagic || big == mhMagic64
    }

    private static func parseFat(data: Data, is64Bit: Bool) throws -> MachOSummary {
        let count = Int(try readUInt32(data, at: 4, endian: .big))
        guard count > 0, count <= 64 else { throw ParseError.invalidHeader }
        let recordSize = is64Bit ? 32 : 20
        let tableEnd = try checkedAdd(8, try checkedMultiply(count, recordSize))
        guard tableEnd <= data.count else { throw ParseError.truncated }

        var slices: [MachOSliceSummary] = []
        for index in 0..<count {
            let recordOffset = 8 + index * recordSize
            let sliceOffset: UInt64
            let sliceSize: UInt64
            if is64Bit {
                sliceOffset = try readUInt64(data, at: recordOffset + 8, endian: .big)
                sliceSize = try readUInt64(data, at: recordOffset + 16, endian: .big)
            } else {
                sliceOffset = UInt64(try readUInt32(data, at: recordOffset + 8, endian: .big))
                sliceSize = UInt64(try readUInt32(data, at: recordOffset + 12, endian: .big))
            }
            guard sliceOffset <= UInt64(Int.max), sliceSize <= UInt64(Int.max) else {
                throw ParseError.invalidHeader
            }
            let start = Int(sliceOffset)
            let end = try checkedAdd(start, Int(sliceSize))
            guard start >= 0, end <= data.count, start < end else { throw ParseError.truncated }
            slices.append(try parseSlice(data: data, offset: start, limit: end))
        }
        return MachOSummary(slices: slices)
    }

    private static func parseSlice(data: Data, offset: Int, limit: Int) throws -> MachOSliceSummary {
        guard try checkedAdd(offset, 4) <= limit else { throw ParseError.truncated }
        let magicLittle = try readUInt32(data, at: offset, endian: .little)
        let magicBig = try readUInt32(data, at: offset, endian: .big)

        let endian: Endian
        let is64Bit: Bool
        if magicLittle == mhMagic || magicLittle == mhMagic64 {
            endian = .little
            is64Bit = magicLittle == mhMagic64
        } else if magicBig == mhMagic || magicBig == mhMagic64 {
            endian = .big
            is64Bit = magicBig == mhMagic64
        } else {
            throw ParseError.notMachO
        }

        let headerSize = is64Bit ? 32 : 28
        guard try checkedAdd(offset, headerSize) <= limit else { throw ParseError.truncated }
        let cpuType = try readUInt32(data, at: offset + 4, endian: endian)
        let fileType = try readUInt32(data, at: offset + 12, endian: endian)
        let commandCount = Int(try readUInt32(data, at: offset + 16, endian: endian))
        let commandBytes = Int(try readUInt32(data, at: offset + 20, endian: endian))
        guard commandCount <= 100_000 else { throw ParseError.invalidHeader }

        let commandsStart = try checkedAdd(offset, headerSize)
        let commandsEnd = try checkedAdd(commandsStart, commandBytes)
        guard commandsEnd <= limit else { throw ParseError.truncated }

        var cursor = commandsStart
        var linkedLibraries: [String] = []
        var commandNames: [String] = []
        var hasCodeSignature = false
        var isEncrypted: Bool?

        for _ in 0..<commandCount {
            guard try checkedAdd(cursor, 8) <= commandsEnd else { throw ParseError.truncated }
            let command = try readUInt32(data, at: cursor, endian: endian)
            let commandSize = Int(try readUInt32(data, at: cursor + 4, endian: endian))
            guard commandSize >= 8 else { throw ParseError.invalidLoadCommand }
            let next = try checkedAdd(cursor, commandSize)
            guard next <= commandsEnd else { throw ParseError.truncated }

            commandNames.append(loadCommandName(command))
            switch command {
            case lcLoadDylib, lcIDDylib, lcLoadWeakDylib, lcReexportDylib, lcLazyLoadDylib, lcLoadUpwardDylib:
                guard commandSize >= 12 else { throw ParseError.invalidLoadCommand }
                let nameOffset = Int(try readUInt32(data, at: cursor + 8, endian: endian))
                if nameOffset >= 8, nameOffset < commandSize {
                    let stringStart = cursor + nameOffset
                    if let name = readCString(data, from: stringStart, to: next), !name.isEmpty {
                        linkedLibraries.append(name)
                    }
                }
            case lcCodeSignature:
                hasCodeSignature = true
            case lcEncryptionInfo, lcEncryptionInfo64:
                guard commandSize >= 20 else { throw ParseError.invalidLoadCommand }
                isEncrypted = try readUInt32(data, at: cursor + 16, endian: endian) != 0
            default:
                break
            }
            cursor = next
        }

        return MachOSliceSummary(
            architecture: architectureName(cpuType),
            fileType: fileTypeName(fileType),
            is64Bit: is64Bit,
            isEncrypted: isEncrypted,
            hasCodeSignature: hasCodeSignature,
            linkedLibraries: Array(Set(linkedLibraries)).sorted(),
            loadCommands: commandNames
        )
    }

    private static func architectureName(_ cpuType: UInt32) -> String {
        switch cpuType {
        case 7: "i386"
        case 0x01000007: "x86_64"
        case 12: "arm"
        case 0x0100000c: "arm64"
        case 0x0200000c: "arm64_32"
        default: String(format: "cpu-0x%08x", cpuType)
        }
    }

    private static func fileTypeName(_ type: UInt32) -> String {
        switch type {
        case 1: "Object"
        case 2: "Executable"
        case 3: "Fixed VM library"
        case 4: "Core"
        case 5: "Preloaded executable"
        case 6: "Dynamic library"
        case 7: "Dynamic linker"
        case 8: "Bundle"
        case 9: "Dynamic library stub"
        case 10: "dSYM companion"
        case 11: "Kext bundle"
        default: "Type \(type)"
        }
    }

    private static func loadCommandName(_ command: UInt32) -> String {
        switch command {
        case lcLoadDylib: "LC_LOAD_DYLIB"
        case lcIDDylib: "LC_ID_DYLIB"
        case lcLoadWeakDylib: "LC_LOAD_WEAK_DYLIB"
        case lcReexportDylib: "LC_REEXPORT_DYLIB"
        case lcLazyLoadDylib: "LC_LAZY_LOAD_DYLIB"
        case lcLoadUpwardDylib: "LC_LOAD_UPWARD_DYLIB"
        case lcCodeSignature: "LC_CODE_SIGNATURE"
        case lcEncryptionInfo: "LC_ENCRYPTION_INFO"
        case lcEncryptionInfo64: "LC_ENCRYPTION_INFO_64"
        case 0x19: "LC_SEGMENT_64"
        case 0x01: "LC_SEGMENT"
        case 0x02: "LC_SYMTAB"
        case 0x0e: "LC_LOAD_DYLINKER"
        case 0x1b: "LC_UUID"
        case 0x80000028: "LC_MAIN"
        case 0x32: "LC_BUILD_VERSION"
        default: String(format: "LC_0x%08x", command)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, endian: Endian) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ParseError.truncated }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return endian == .big ? value : value.byteSwapped
    }

    private static func readUInt64(_ data: Data, at offset: Int, endian: Endian) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw ParseError.truncated }
        let value = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return endian == .big ? value : value.byteSwapped
    }

    private static func readCString(_ data: Data, from start: Int, to end: Int) -> String? {
        guard start >= 0, start < end, end <= data.count else { return nil }
        let bytes = data[start..<end]
        let terminator = bytes.firstIndex(of: 0) ?? end
        return String(data: data[start..<terminator], encoding: .utf8)
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { throw ParseError.invalidHeader }
        return value
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        if overflow { throw ParseError.invalidHeader }
        return value
    }

    public enum ParseError: LocalizedError, Sendable {
        case notMachO
        case truncated
        case invalidHeader
        case invalidLoadCommand

        public var errorDescription: String? {
            switch self {
            case .notMachO: "The file is not a Mach-O binary."
            case .truncated: "The Mach-O data ends before the declared structure is complete."
            case .invalidHeader: "The Mach-O header contains invalid bounds."
            case .invalidLoadCommand: "A Mach-O load command contains invalid bounds."
            }
        }
    }
}
