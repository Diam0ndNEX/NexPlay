import Foundation

// Ren'Py archives (.rpa) are unpacked into loose files when a Ren'Py game is imported. The web runtime keeps every
// file of game.zip in memory, and a 2 GB images.rpa would not fit; loose images, music and videos are fetched only
// when the game needs them. Format (renpy/loader.py, RPAv3/RPAv2 handlers, MIT):
//   "RPA-3.0 <16 hex digits: index offset> <8 hex digits: key>\n" ... index = zlib(pickle(dict)) at the offset,
//   name -> [(offset ^ key, length ^ key[, prefix bytes])]; a file is prefix + bytes[offset ..< offset + length].
//   "RPA-2.0 <16 hex digits: index offset>\n" is the same without the key.
// Archives with any other header (games that use their own format) are left as they are.

enum RenPyArchive {
    struct Report {
        var archives = 0
        var files = 0
        var skipped: [String] = []
    }

    enum ArchiveError: LocalizedError {
        case notAnArchive
        case badIndex(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: return "not an RPA-2.0/3.0 archive"
            case .badIndex(let detail): return "unreadable index (\(detail))"
            }
        }
    }

    /// Unpacks every .rpa in `gameDir` (two levels deep) into it and removes the archives that were unpacked
    /// completely. Files that already exist are kept (loose files win in Ren'Py too).
    static func unpackAll(in gameDir: URL, cancel: ImportCancel?) throws -> Report {
        let fm = FileManager.default
        var report = Report()
        var archives: [URL] = []
        var level = [gameDir]
        for _ in 0...1 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        next.append(kid)
                    } else if kid.pathExtension.lowercased() == "rpa" {
                        archives.append(kid)
                    }
                }
            }
            level = next
        }
        for (index, archive) in archives.enumerated() {
            try cancel?.check()
            cancel?.report(.scanning, "Unpacking \(archive.lastPathComponent)…",
                           Double(index) / Double(max(archives.count, 1)), force: true)
            do {
                let count = try unpack(archive, into: archive.deletingLastPathComponent(), cancel: cancel)
                report.archives += 1
                report.files += count
                try? fm.removeItem(at: archive)
            } catch PipelineError.cancelled {
                throw PipelineError.cancelled
            } catch PipelineError.outOfSpace {
                throw PipelineError.outOfSpace
            } catch {
                let ns = error as NSError
                if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { throw PipelineError.outOfSpace }
                report.skipped.append("\(archive.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Unpacks one archive into `folder`. Returns the number of files written.
    static func unpack(_ archive: URL, into folder: URL, cancel: ImportCancel?) throws -> Int {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 64), head.count >= 24 else { throw ArchiveError.notAnArchive }
        let line = String(decoding: head.prefix { $0 != 0x0A }, as: UTF8.self)
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0] == "RPA-3.0" || parts[0] == "RPA-2.0",
              let indexOffset = UInt64(parts[1], radix: 16) else { throw ArchiveError.notAnArchive }
        var key: Int64 = 0
        if parts[0] == "RPA-3.0" {
            guard parts.count >= 3, let value = UInt64(parts[2], radix: 16) else { throw ArchiveError.notAnArchive }
            key = Int64(value)
        }
        try handle.seek(toOffset: indexOffset)
        guard let packed = try handle.readToEnd(), packed.count > 2 else { throw ArchiveError.badIndex("empty") }
        guard let raw = inflateZlib(packed) else { throw ArchiveError.badIndex("zlib") }
        var parser = PickleParser(data: raw)
        let root = try parser.parse()
        guard case .dict(let box) = root else { throw ArchiveError.badIndex("not a dict") }

        let fm = FileManager.default
        let base = folder.standardizedFileURL
        var written = 0
        for (nameValue, entriesValue) in box.pairs {
            if written % 64 == 0 { try cancel?.check() }
            guard let name = nameValue.asText else { continue }
            let clean = name.replacingOccurrences(of: "\\", with: "/")
            let components = clean.split(separator: "/").map(String.init)
            if components.isEmpty || components.contains("..") || clean.hasPrefix("/") { continue }
            var target = base
            for part in components { target.appendPathComponent(part) }
            if fm.fileExists(atPath: target.path) { continue }

            var pieces: [(offset: Int64, length: Int64, prefix: Data)] = []
            for item in entriesValue.asItems {
                let fields = item.asItems
                guard fields.count >= 2, let rawOffset = fields[0].asInt, let rawLength = fields[1].asInt else { continue }
                let prefix = fields.count >= 3 ? (fields[2].asBytes ?? Data()) : Data()
                pieces.append((rawOffset ^ key, rawLength ^ key, prefix))
            }
            guard !pieces.isEmpty else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target)
            do {
                for piece in pieces {
                    if !piece.prefix.isEmpty { try output.write(contentsOf: piece.prefix) }
                    guard piece.offset >= 0, piece.length >= 0 else { throw ArchiveError.badIndex("negative offset") }
                    try handle.seek(toOffset: UInt64(piece.offset))
                    var remaining = piece.length
                    while remaining > 0 {
                        let size = Int(min(Int64(4 << 20), remaining))
                        guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { break }
                        try output.write(contentsOf: chunk)
                        remaining -= Int64(chunk.count)
                    }
                }
                try output.close()
            } catch {
                try? output.close()
                try? fm.removeItem(at: target)
                throw error
            }
            written += 1
        }
        return written
    }

    /// zlib stream (2-byte header, deflate, Adler-32) to bytes. NSData's .zlib is raw deflate, so the header goes.
    static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let body = data.subdata(in: 2..<(data.count - 4))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

// MARK: - A small pickle reader (the subset Ren'Py's archive index uses, protocols 0-5)

final class PickleList {
    var items: [PickleValue] = []
}

final class PickleDict {
    var pairs: [(PickleValue, PickleValue)] = []
}

enum PickleValue {
    case none
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case text(String)
    case bytes(Data)
    case list(PickleList)
    case tuple([PickleValue])
    case dict(PickleDict)
    case global(String)
    case mark

    var asText: String? {
        switch self {
        case .text(let value): return value
        case .bytes(let value): return String(data: value, encoding: .utf8) ?? String(data: value, encoding: .isoLatin1)
        default: return nil
        }
    }

    var asInt: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var asBytes: Data? {
        switch self {
        case .bytes(let value): return value
        case .text(let value): return value.data(using: .isoLatin1) ?? Data(value.utf8)
        case .none: return Data()
        default: return nil
        }
    }

    /// The elements of a list or tuple.
    var asItems: [PickleValue] {
        switch self {
        case .list(let box): return box.items
        case .tuple(let values): return values
        default: return []
        }
    }
}

struct PickleParser {
    enum ParseError: LocalizedError {
        case truncated
        case unsupported(UInt8)
        case stack

        var errorDescription: String? {
            switch self {
            case .truncated: return "pickle ends early"
            case .unsupported(let op): return String(format: "pickle opcode 0x%02x", op)
            case .stack: return "pickle stack"
            }
        }
    }

    private let data: [UInt8]
    private var position = 0
    private var stack: [PickleValue] = []
    private var memo: [Int: PickleValue] = [:]

    init(data: Data) {
        self.data = [UInt8](data)
    }

    private mutating func byte() throws -> UInt8 {
        guard position < data.count else { throw ParseError.truncated }
        defer { position += 1 }
        return data[position]
    }

    private mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw ParseError.truncated }
        defer { position += count }
        return Array(data[position..<(position + count)])
    }

    private mutating func uint(_ count: Int) throws -> UInt64 {
        let raw = try bytes(count)
        var value: UInt64 = 0
        for (index, b) in raw.enumerated() { value |= UInt64(b) << (8 * UInt64(index)) }
        return value
    }

    private mutating func line() throws -> String {
        var raw: [UInt8] = []
        while true {
            let b = try byte()
            if b == 0x0A { break }
            raw.append(b)
        }
        return String(decoding: raw, as: UTF8.self)
    }

    private mutating func pop() throws -> PickleValue {
        guard let value = stack.popLast() else { throw ParseError.stack }
        return value
    }

    /// Everything above the last mark, which is removed.
    private mutating func popToMark() throws -> [PickleValue] {
        var values: [PickleValue] = []
        while let value = stack.popLast() {
            if case .mark = value { return values.reversed() }
            values.append(value)
        }
        throw ParseError.stack
    }

    private mutating func appendItems(_ values: [PickleValue]) throws {
        guard let top = stack.last else { throw ParseError.stack }
        if case .list(let box) = top { box.items.append(contentsOf: values) }
    }

    private mutating func setItems(_ values: [PickleValue]) throws {
        guard let top = stack.last else { throw ParseError.stack }
        guard case .dict(let box) = top else { return }
        var index = 0
        while index + 1 < values.count {
            box.pairs.append((values[index], values[index + 1]))
            index += 2
        }
    }

    /// Two's-complement little-endian integer (LONG1/LONG4).
    private func long(_ raw: [UInt8]) -> Int64 {
        guard !raw.isEmpty else { return 0 }
        var value: UInt64 = 0
        for (index, b) in raw.prefix(8).enumerated() { value |= UInt64(b) << (8 * UInt64(index)) }
        if raw.count < 8, let last = raw.last, last & 0x80 != 0 {
            value |= ~UInt64(0) << (8 * UInt64(raw.count))
        }
        return Int64(bitPattern: value)
    }

    private static func string(_ raw: [UInt8]) -> String {
        String(decoding: raw, as: UTF8.self)
    }

    mutating func parse() throws -> PickleValue {
        while true {
            let op = try byte()
            switch op {
            case 0x80: _ = try byte()                                   // PROTO
            case 0x95: _ = try uint(8)                                  // FRAME
            case 0x2E: return try pop()                                 // STOP
            case 0x28: stack.append(.mark)                              // MARK
            case 0x4E: stack.append(.none)                              // NONE
            case 0x88: stack.append(.bool(true))                        // NEWTRUE
            case 0x89: stack.append(.bool(false))                       // NEWFALSE
            case 0x7D: stack.append(.dict(PickleDict()))                // EMPTY_DICT
            case 0x5D: stack.append(.list(PickleList()))                // EMPTY_LIST
            case 0x29: stack.append(.tuple([]))                         // EMPTY_TUPLE
            case 0x64:                                                  // DICT
                let values = try popToMark()
                let box = PickleDict()
                var index = 0
                while index + 1 < values.count { box.pairs.append((values[index], values[index + 1])); index += 2 }
                stack.append(.dict(box))
            case 0x6C:                                                  // LIST
                let box = PickleList()
                box.items = try popToMark()
                stack.append(.list(box))
            case 0x74: stack.append(.tuple(try popToMark()))            // TUPLE
            case 0x85: let a = try pop(); stack.append(.tuple([a]))     // TUPLE1
            case 0x86: let b = try pop(); let a = try pop(); stack.append(.tuple([a, b]))
            case 0x87: let c = try pop(); let b = try pop(); let a = try pop(); stack.append(.tuple([a, b, c]))
            case 0x61: let value = try pop(); try appendItems([value])  // APPEND
            case 0x65: let values = try popToMark(); try appendItems(values)
            case 0x73: let value = try pop(); let key = try pop(); try setItems([key, value])
            case 0x75: let values = try popToMark(); try setItems(values)
            case 0x4A: stack.append(.int(Int64(Int32(bitPattern: UInt32(try uint(4))))))   // BININT
            case 0x4B: stack.append(.int(Int64(try byte())))                               // BININT1
            case 0x4D: stack.append(.int(Int64(try uint(2))))                              // BININT2
            case 0x8A: let n = Int(try byte()); stack.append(.int(long(try bytes(n))))       // LONG1
            case 0x8B: let n = Int(try uint(4)); stack.append(.int(long(try bytes(n))))      // LONG4
            case 0x49:                                                                     // INT
                let text = try line()
                if text == "01" { stack.append(.bool(true)) } else if text == "00" { stack.append(.bool(false)) }
                else { stack.append(.int(Int64(text) ?? 0)) }
            case 0x4C:                                                                     // LONG
                var text = try line()
                if text.hasSuffix("L") { text.removeLast() }
                stack.append(.int(Int64(text) ?? 0))
            case 0x47: stack.append(.float(Double(bitPattern: UInt64(bigEndianBytes: try bytes(8)))))  // BINFLOAT
            case 0x58: let n = Int(try uint(4)); stack.append(.text(PickleParser.string(try bytes(n))))   // BINUNICODE
            case 0x8C: let n = Int(try byte()); stack.append(.text(PickleParser.string(try bytes(n))))    // SHORT_BINUNICODE
            case 0x8D: let n = Int(try uint(8)); stack.append(.text(PickleParser.string(try bytes(n))))   // BINUNICODE8
            case 0x54: let n = Int(try uint(4)); stack.append(.bytes(Data(try bytes(n))))                  // BINSTRING
            case 0x55: let n = Int(try byte()); stack.append(.bytes(Data(try bytes(n))))                   // SHORT_BINSTRING
            case 0x42: let n = Int(try uint(4)); stack.append(.bytes(Data(try bytes(n))))                  // BINBYTES
            case 0x43: let n = Int(try byte()); stack.append(.bytes(Data(try bytes(n))))                   // SHORT_BINBYTES
            case 0x8E: let n = Int(try uint(8)); stack.append(.bytes(Data(try bytes(n))))                  // BINBYTES8
            case 0x56: stack.append(.text(try line()))                                                      // UNICODE
            case 0x53:                                                                                      // STRING
                var text = try line()
                if text.count >= 2, let first = text.first, first == "'" || first == "\"" {
                    text = String(text.dropFirst().dropLast())
                }
                stack.append(.bytes(Data(text.utf8)))
            case 0x94: if let top = stack.last { memo[memo.count] = top }                // MEMOIZE
            case 0x71: let index = Int(try byte()); if let top = stack.last { memo[index] = top }    // BINPUT
            case 0x72: let index = Int(try uint(4)); if let top = stack.last { memo[index] = top }   // LONG_BINPUT
            case 0x70: let index = Int(try line()) ?? 0; if let top = stack.last { memo[index] = top }   // PUT
            case 0x68: stack.append(memo[Int(try byte())] ?? PickleValue.none)                    // BINGET
            case 0x6A: stack.append(memo[Int(try uint(4))] ?? PickleValue.none)                   // LONG_BINGET
            case 0x67: stack.append(memo[Int(try line()) ?? 0] ?? PickleValue.none)               // GET
            case 0x63:                                                                 // GLOBAL
                let module = try line()
                let name = try line()
                stack.append(.global(module + "." + name))
            case 0x93:                                                                 // STACK_GLOBAL
                let name = try pop().asText ?? ""
                let module = try pop().asText ?? ""
                stack.append(.global(module + "." + name))
            case 0x52:                                                                 // REDUCE
                let args = try pop()
                let function = try pop()
                stack.append(PickleParser.reduce(function, args.asItems))
            case 0x81:                                                                 // NEWOBJ
                _ = try pop()
                _ = try pop()
                stack.append(.none)
            default:
                throw ParseError.unsupported(op)
            }
        }
    }

    /// Python 3 pickles bytes with protocol 2 as _codecs.encode(text, "latin1"), and b"" as bytes().
    private static func reduce(_ function: PickleValue, _ args: [PickleValue]) -> PickleValue {
        guard case .global(let name) = function else { return .none }
        if name.hasSuffix(".encode"), let text = args.first?.asText {
            let encoding = args.count > 1 ? (args[1].asText ?? "latin1") : "latin1"
            if encoding.lowercased().contains("utf") { return .bytes(Data(text.utf8)) }
            return .bytes(text.data(using: .isoLatin1) ?? Data(text.utf8))
        }
        if name.hasSuffix(".bytes") || name.hasSuffix(".bytearray") {
            if let first = args.first { return .bytes(first.asBytes ?? Data()) }
            return .bytes(Data())
        }
        return .none
    }
}

private extension UInt64 {
    init(bigEndianBytes raw: [UInt8]) {
        var value: UInt64 = 0
        for b in raw { value = (value << 8) | UInt64(b) }
        self = value
    }
}
