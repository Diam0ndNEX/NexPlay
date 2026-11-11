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
        let archiveName = url.lastPathComponent
        guard let reader = archive_read_new() else {
            throw PipelineError.archiveFailed(archiveName, "libarchive could not start")
        }
        defer { _ = archive_read_free(reader) }
        _ = archive_read_support_filter_all(reader)
        _ = archive_read_support_format_all(reader)
        let opened = url.path.withCString { archive_read_open_filename(reader, $0, 1 << 20) }
        guard opened == ok else { throw PipelineError.archiveFailed(archiveName, errorText(reader)) }

        let fm = FileManager.default
        var entry: OpaquePointer?
        var entryCount = 0
        var fileCount = 0
        while true {
            if entryCount % 20 == 0 { try cancel.check() }
            let result = archive_read_next_header(reader, &entry)
            if result == eof { break }
            if result == retry { continue }
            if result < warn { throw PipelineError.archiveFailed(archiveName, errorText(reader)) }
            guard let entry else { continue }
            entryCount += 1

            guard let rawName = entryName(of: entry) else {
                _ = archive_read_data_skip(reader)
                continue
            }
            let relative = rawName.replacingOccurrences(of: "\\", with: "/")
            let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.isEmpty {
                _ = archive_read_data_skip(reader)
                continue
            }
            if parts.contains("..") || relative.hasPrefix("/") { throw PipelineError.unsafePath(relative) }
            if parts.first == "__MACOSX" || parts.last == ".DS_Store" {
                _ = archive_read_data_skip(reader)
                continue
            }
            var target = destination
            for part in parts { target.appendPathComponent(part) }

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
            if fileCount % 25 == 0 { status("Unpacking \(parts.last ?? archiveName)…") }
            fileCount += 1
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeEntry(reader, to: target, archiveName: archiveName)
        }
        if fileCount == 0 { throw PipelineError.archiveFailed(archiveName, "no files inside") }
    }

    /// The entry's path as UTF-8 (7z and RAR5 store Unicode names), else the raw name.
    private static func entryName(of entry: OpaquePointer) -> String? {
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
