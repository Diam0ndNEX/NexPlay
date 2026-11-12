import Foundation

/// Writes a ZIP whose entries are stored (not compressed), one after another, then the central directory once.
/// ZIPFoundation rewrites the central directory after every entry, which is slow for thousands of files; this is
/// all the Ren'Py game.zip needs. No ZIP64: the archive must stay under 4 GB (the writer throws past that).
final class StoredZipWriter {
    enum WriterError: LocalizedError {
        case tooLarge
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The game package would be larger than 4 GB."
            case .unreadable(let name): return "\(name) could not be read."
            }
        }
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0
    private var names = Set<String>()

    init(url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    /// True when an entry of that name was added already (the first one wins).
    func contains(_ name: String) -> Bool { names.contains(name) }

    func add(name: String, data: Data, date: Date = Date()) throws {
        guard !names.contains(name) else { return }
        let crc = CRC32.checksum(data)
        try writeHeader(name: name, crc: crc, size: UInt64(data.count), date: date)
        try write(data)
    }

    /// Adds a file from disk (read twice in 4 MB chunks: once for the checksum, once to copy it).
    func add(name: String, file: URL) throws {
        guard !names.contains(name) else { return }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(values?.fileSize ?? 0)
        let date = values?.contentModificationDate ?? Date()
        guard let reader = try? FileHandle(forReadingFrom: file) else { throw WriterError.unreadable(file.lastPathComponent) }
        defer { try? reader.close() }
        var crc = CRC32()
        var total: UInt64 = 0
        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            crc.update(chunk)
            total += UInt64(chunk.count)
        }
        guard total == size else { throw WriterError.unreadable(file.lastPathComponent) }
        try writeHeader(name: name, crc: crc.value, size: size, date: date)
        try reader.seek(toOffset: 0)
        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            try write(chunk)
        }
    }

    /// Writes the central directory and closes the file.
    func finish() throws {
        let start = offset
        try write(central)
        guard offset < 0xFFFF_FFFF, count < 0xFFFF else { throw WriterError.tooLarge }
        var end = Data()
        end.append(u32: 0x0605_4b50)
        end.append(u16: 0)
        end.append(u16: 0)
        end.append(u16: UInt16(count))
        end.append(u16: UInt16(count))
        end.append(u32: UInt32(central.count))
        end.append(u32: UInt32(start))
        end.append(u16: 0)
        try write(end)
        try handle.close()
    }

    private func writeHeader(name: String, crc: UInt32, size: UInt64, date: Date) throws {
        guard offset + size + 1024 < 0xFFFF_FFFF, size < 0xFFFF_FFFF else { throw WriterError.tooLarge }
        names.insert(name)
        let nameData = Data(name.utf8)
        let (dosTime, dosDate) = StoredZipWriter.dosDateTime(date)
        let headerOffset = offset

        var local = Data()
        local.append(u32: 0x0403_4b50)
        local.append(u16: 10)            // version needed
        local.append(u16: 0x0800)        // UTF-8 names
        local.append(u16: 0)             // stored
        local.append(u16: dosTime)
        local.append(u16: dosDate)
        local.append(u32: crc)
        local.append(u32: UInt32(size))
        local.append(u32: UInt32(size))
        local.append(u16: UInt16(nameData.count))
        local.append(u16: 0)
        local.append(nameData)
        try write(local)

        central.append(u32: 0x0201_4b50)
        central.append(u16: 0x031E)      // made by Unix, 3.0
        central.append(u16: 10)
        central.append(u16: 0x0800)
        central.append(u16: 0)
        central.append(u16: dosTime)
        central.append(u16: dosDate)
        central.append(u32: crc)
        central.append(u32: UInt32(size))
        central.append(u32: UInt32(size))
        central.append(u16: UInt16(nameData.count))
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u16: 0)
        central.append(u32: UInt32(0o100644) << 16)
        central.append(u32: UInt32(headerOffset))
        central.append(nameData)
        count += 1
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

/// CRC-32 (ZIP polynomial 0xEDB88320).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var crc = state
        let table = CRC32.table
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        state = crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

extension Data {
    mutating func append(u16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(u32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
