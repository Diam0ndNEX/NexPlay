import Foundation

// Reads 7z, RAR, TAR and other archives with the libarchive that ships with iOS, entry by entry, straight to disk.
// Adapted from Empo's ArchiveExtractor.swift (streaming read loop, path-escape check, __MACOSX skip).
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).
// The C declarations are in NexPlay-Bridging-Header.h.

enum ArchiveExtractor {
    // libarchive return codes (archive.h).
    private static let eof: Int32 = 1
    private static let ok: Int32 = 0
    private static let retry: Int32 = -10
    private static let warn: Int32 = -20

    /// Extensions handed to libarchive. ZIP stays with ZIPFoundation (it repairs Japanese/Chinese file names);
    /// a ZIP ZIPFoundation can't open falls back to libarchive too.
    static let extensions: Set<String> = [
        "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma", "zst", "cab", "iso",
        "cpio", "lha", "lzh", "exe",
    ]

    /// Unpacks `url` into `destination`. Self-extracting .exe files work when the payload is 7z, RAR or ZIP.
    static func extract(_ url: URL, to destination: URL, cancel: ImportCancel, status: (String) -> Void) throws {
        try extract([url], password: nil, to: destination, cancel: cancel, status: status)
    }

    /// 8.19.0: `parts` are the volumes of one archive in order (one URL for a normal archive); `password` is tried for
    /// encrypted entries. An encrypted archive without the right password throws `PipelineError.needsPassword`.
    static func extract(_ parts: [URL], password: String?, to destination: URL, cancel: ImportCancel,
                        status: (String) -> Void) throws {
        guard let url = parts.first else { throw PipelineError.archiveFailed("archive", "no file") }
        let archiveName = url.lastPathComponent
        guard let reader = archive_read_new() else {
            throw PipelineError.archiveFailed(archiveName, "libarchive could not start")
        }
        defer { _ = archive_read_free(reader) }
        _ = archive_read_support_filter_all(reader)
        _ = archive_read_support_format_all(reader)
        if let password, !password.isEmpty {
            _ = password.withCString { archive_read_add_passphrase(reader, $0) }
        }
        // 8.20.0 (after Empo #311): a zip made on a Japanese/Chinese/Korean Windows PC stores its names in that code
        // page without the UTF-8 flag. NexPlay decodes those names itself: libarchive's own conversion (hdrcharset)
        // converts into the process's C locale and gives no name at all there (checked on Linux).
        let legacyEncoding = parts.count == 1 ? legacyZipEncoding(url) : nil
        let opened: Int32
        if parts.count == 1 {
            opened = url.path.withCString { archive_read_open_filename(reader, $0, 1 << 20) }
        } else {
            // A NULL-terminated array of C strings that lives until the reader is freed.
            let names = parts.map { strdup($0.path) }
            var pointers: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
            pointers.append(nil)
            opened = pointers.withUnsafeMutableBufferPointer { buffer in
                archive_read_open_filenames(reader, buffer.baseAddress, 1 << 20)
            }
            // libarchive copies the names when opening, so they can go now.
            names.forEach { free($0) }
        }
        guard opened == ok else { throw failure(reader, archiveName, password: password) }

        let fm = FileManager.default
        var archiveBytes: Int64 = 0
        for part in parts {
            archiveBytes += (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var entry: OpaquePointer?
        var entryCount = 0
        var fileCount = 0
        while true {
            if entryCount % 20 == 0 { try cancel.check() }
            let result = archive_read_next_header(reader, &entry)
            if result == eof { break }
            if result == retry { continue }
            if result < warn { throw failure(reader, archiveName, password: password) }
            guard let entry else { continue }
            entryCount += 1

            guard let rawName = entryName(of: entry, legacy: legacyEncoding) else {
                _ = archive_read_data_skip(reader)
                continue
            }
            let relative = rawName.replacingOccurrences(of: "\\", with: "/")
            let pieces = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if pieces.isEmpty {
                _ = archive_read_data_skip(reader)
                continue
            }
            if pieces.contains("..") || relative.hasPrefix("/") { throw PipelineError.unsafePath(relative) }
            if pieces.first == "__MACOSX" || pieces.last == ".DS_Store" {
                _ = archive_read_data_skip(reader)
                continue
            }
            var target = destination
            for piece in pieces { target.appendPathComponent(piece) }

            let kind = Int(archive_entry_filetype(entry)) & 0o170000
            if kind == 0o040000 {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // Regular files only (0 is what some formats report for them); links and devices are skipped.
            if kind != 0o100000 && kind != 0 {
                _ = archive_read_data_skip(reader)
                continue
            }
            if fileCount % 25 == 0 { status("Unpacking \(pieces.last ?? archiveName)…") }
            // How far into the archive file libarchive has read (-1 = the raw file), as the percentage.
            let consumed = archive_filter_bytes(reader, -1)
            let fraction: Double? = archiveBytes > 0 && consumed >= 0 ? Double(consumed) / Double(archiveBytes) : nil
            cancel.report(.extracting, "\(pieces.last ?? archiveName) · \(fileCount + 1) files", fraction)
            fileCount += 1
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try writeEntry(reader, to: target, archiveName: archiveName)
            } catch PipelineError.archiveFailed(_, _) {
                throw failure(reader, archiveName, password: password)
            }
        }
        if fileCount == 0 { throw PipelineError.archiveFailed(archiveName, "no files inside") }
    }

    /// The error for a failed read: a password problem when libarchive says so, else the plain failure.
    private static func failure(_ reader: OpaquePointer, _ name: String, password: String?) -> Error {
        let text = errorText(reader)
        let lower = text.lowercased()
        if lower.contains("passphrase") || lower.contains("password") || lower.contains("encrypt") || lower.contains("decrypt") {
            return PipelineError.needsPassword(name, wrong: password?.isEmpty == false)
        }
        if lower.contains("truncated") || lower.contains("premature end") || lower.contains("multivolume")
            || lower.contains("multi-volume") {
            return PipelineError.archiveFailed(name, text + ". If it is split into parts, pick every part together")
        }
        return PipelineError.archiveFailed(name, text)
    }

    /// The code page of a zip's names that are not UTF-8 (Shift-JIS, GB18030, Big5, Korean), or nil: not a zip, no such
    /// names, or no code page reads all of them. Reads only the headers.
    private static func legacyZipEncoding(_ url: URL) -> String.Encoding? {
        guard let reader = archive_read_new() else { return nil }
        defer { _ = archive_read_free(reader) }
        _ = archive_read_support_filter_all(reader)
        _ = archive_read_support_format_all(reader)
        guard url.path.withCString({ archive_read_open_filename(reader, $0, 1 << 20) }) == ok else { return nil }
        var legacy: [Data] = []
        var entry: OpaquePointer?
        while true {
            let result = archive_read_next_header(reader, &entry)
            if result == eof || result < warn { break }
            if result == retry { continue }
            // Only zips: in a solid 7z every skip unpacks the data.
            guard archive_format(reader) & 0xff0000 == 0x50000 else { return nil }
            if let entry, let raw = archive_entry_pathname(entry) {
                let bytes = Data(bytes: raw, count: strlen(raw))
                if String(data: bytes, encoding: .utf8) == nil { legacy.append(bytes) }
            }
            _ = archive_read_data_skip(reader)
        }
        guard !legacy.isEmpty else { return nil }
        func cf(_ value: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
        let candidates: [String.Encoding] = [.shiftJIS, cf(.GB_18030_2000), cf(.big5), cf(.dosKorean)]
        let fitting = candidates.filter { encoding in legacy.allSatisfy { decodeLegacy($0, encoding) != nil } }
        // Japanese names nearly always have kana; GB18030 decodes almost anything, so it is not the first guess.
        if fitting.contains(.shiftJIS),
           legacy.contains(where: { data in
               (decodeLegacy(data, .shiftJIS) ?? "").unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
           }) {
            return .shiftJIS
        }
        return fitting.first { $0 == cf(.GB_18030_2000) } ?? fitting.first
    }

    /// A legacy name in `encoding`. libarchive turns a 0x5C byte into "/" in a zip name without "/"; in Shift-JIS
    /// 0x5C is the second byte of ソ, 表, 能, so a failed read is tried again with those bytes put back.
    private static func decodeLegacy(_ bytes: Data, _ encoding: String.Encoding) -> String? {
        if let name = String(data: bytes, encoding: encoding) { return name }
        guard !bytes.contains(0x5C) else { return nil }
        return String(data: Data(bytes.map { $0 == 0x2F ? 0x5C : $0 }), encoding: encoding)
    }

    /// The entry's path: UTF-8 when it is (7z and RAR5 store Unicode names, flagged zip names), else the zip's legacy
    /// code page, else the raw bytes read leniently.
    private static func entryName(of entry: OpaquePointer, legacy: String.Encoding? = nil) -> String? {
        if let raw = archive_entry_pathname(entry) {
            let bytes = Data(bytes: raw, count: strlen(raw))
            if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
            if let legacy, let name = decodeLegacy(bytes, legacy) { return name }
        }
        if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
        if let plain = archive_entry_pathname(entry) { return String(cString: plain) }
        return nil
    }

    private static func errorText(_ reader: OpaquePointer) -> String {
        guard let text = archive_error_string(reader) else { return "unknown error" }
        return String(cString: text)
    }

    private static func writeEntry(_ reader: OpaquePointer, to target: URL, archiveName: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        guard let stream = OutputStream(url: target, append: false) else {
            throw PipelineError.archiveFailed(archiveName, "can't write \(target.lastPathComponent)")
        }
        stream.open()
        defer { stream.close() }
        while true {
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            let result = archive_read_data_block(reader, &buffer, &size, &offset)
            if result == eof { break }
            if result < warn { throw PipelineError.archiveFailed(archiveName, errorText(reader)) }
            guard size > 0, let buffer else { continue }
            var written = 0
            while written < size {
                let pointer = buffer.advanced(by: written).assumingMemoryBound(to: UInt8.self)
                let wrote = stream.write(pointer, maxLength: size - written)
                if wrote <= 0 {
                    let streamError: NSError? = stream.streamError.map { $0 as NSError }
                    if let streamError, streamError.domain == NSPOSIXErrorDomain, streamError.code == Int(ENOSPC) {
                        throw PipelineError.outOfSpace
                    }
                    throw PipelineError.archiveFailed(archiveName, streamError?.localizedDescription ?? "write failed")
                }
                written += wrote
            }
        }
    }
}

/// 8.19.0: volumes of split archives: "Game.part1.rar" + "Game.part2.rar", "Game.rar" + "Game.r00", "Game.7z.001" +
/// "Game.7z.002", "Game.zip.001"... Picked together they become one import with the parts in order.
enum ArchiveParts {
    /// The set a file belongs to and its position, or nil for a file that is not a volume.
    static func volume(_ url: URL) -> (key: String, index: Int)? {
        let name = url.lastPathComponent.lowercased()
        let folder = url.deletingLastPathComponent().path
        // name.partN.rar
        if let range = name.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
            let digits = name[range].dropFirst(5).dropLast(4)
            return (folder + "/" + String(name[..<range.lowerBound]) + ".rar", Int(digits) ?? 0)
        }
        // name.rar (first) + name.r00, name.r01...
        if let range = name.range(of: #"\.r(\d\d)$"#, options: .regularExpression) {
            let digits = name[range].dropFirst(2)
            return (folder + "/" + String(name[..<range.lowerBound]) + ".rar", (Int(digits) ?? 0) + 2)
        }
        // name.7z.001, name.zip.001, name.001
        if let range = name.range(of: #"\.(\d{3})$"#, options: .regularExpression) {
            let digits = name[range].dropFirst()
            return (folder + "/" + String(name[..<range.lowerBound]), Int(digits) ?? 0)
        }
        return nil
    }

    /// True for a later volume (part2+, .r00+, .002+): imported only together with its first part.
    static func isLaterVolume(_ url: URL) -> Bool {
        guard let volume = volume(url) else { return false }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".rar") && !name.contains(".part") { return false }
        return volume.index > 1
    }

    /// Groups picked URLs: each split set becomes one entry (first part first); everything else stays on its own.
    /// "Game.rar" is the first volume of a set when "Game.r00" was picked with it.
    static func group(_ urls: [URL]) -> [[URL]] {
        var sets: [String: [(Int, URL)]] = [:]
        var order: [String] = []
        var singles: [(String, URL)] = []
        let rarKeys = Set(urls.compactMap { url -> String? in
            guard let v = volume(url), url.lastPathComponent.lowercased().range(of: #"\.r\d\d$"#, options: .regularExpression) != nil else { return nil }
            return v.key
        })
        for url in urls {
            var entry = volume(url)
            let lowerPath = url.deletingLastPathComponent().path + "/" + url.lastPathComponent.lowercased()
            if entry == nil, url.pathExtension.lowercased() == "rar", rarKeys.contains(lowerPath) {
                entry = (lowerPath, 1)
            }
            guard let entry else {
                singles.append((url.path, url))
                continue
            }
            if sets[entry.key] == nil { order.append(entry.key) }
            sets[entry.key, default: []].append((entry.index, url))
        }
        var result: [[URL]] = order.compactMap { key in
            let parts = (sets[key] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            return parts.isEmpty ? nil : parts
        }
        result += singles.map { [$0.1] }
        return result
    }

    /// The other volumes next to `first` that NexPlay can read (an Inbox or download folder), in order.
    static func siblings(of first: URL) -> [URL] {
        guard let mine = volume(first) ?? (first.pathExtension.lowercased() == "rar"
              ? (first.deletingLastPathComponent().path + "/" + first.lastPathComponent.lowercased(), 1) : nil) else { return [first] }
        let folder = first.deletingLastPathComponent()
        let kids = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [(Int, URL)] = []
        for kid in kids {
            if let v = volume(kid), v.key == mine.key { found.append((v.index, kid)) }
        }
        if !found.contains(where: { $0.1.lastPathComponent == first.lastPathComponent }) { found.append((mine.index, first)) }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
