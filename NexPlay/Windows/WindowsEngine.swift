import Foundation

// 8.0.0: the Windows engine is part of NexPlay. BCD's app code (by thebcd69, a fork of Madeira by Will Faust) is
// compiled into NexPlay from NexPlay/Windows/BCD when the build has the engine (NEXPLAY_WINDOWS: the build workflow
// downloads the newest windows-engine-* release, made by the "Build Windows runtime" workflow, and turns
// NexPlayWindows.yml on). Wine, FEX, DXMT and the Windows DLLs come prebuilt from that release. Builds without it
// still build and run every other engine; Windows games then say how to get the engine.
// BCD: https://github.com/thebcd69/bcd-games (GPL-3.0 with BCD's additional terms and the Madeira Converter Exception).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

enum WindowsEngine {
    /// True when BCD's engine is compiled into this build.
    static var isBuiltIn: Bool {
        #if NEXPLAY_WINDOWS
        return true
        #else
        return false
        #endif
    }

    /// The engine release merged into this build (windows-engine-<BCD tag>-<run>), or nil.
    static var version: String? {
        guard let url = Bundle.main.url(forResource: "WindowsEngine", withExtension: "version"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The Windows files the engine needs at run time (DLL folders, prefix template) are in the app.
    static var filesPresent: Bool {
        let fm = FileManager.default
        let base = Bundle.main.bundleURL
        return fm.fileExists(atPath: base.appendingPathComponent("aarch64-windows").path)
            && fm.fileExists(atPath: base.appendingPathComponent("prefix-template.tar.gz").path)
    }

    /// Why Windows games can't start in this build, or nil.
    static var unavailableReason: String? {
        if !isBuiltIn {
            return "This build has no Windows engine. Run the \"Build Windows runtime\" workflow once, then build NexPlay again."
        }
        if !filesPresent {
            return "The Windows engine's files are missing from this app. Build NexPlay again (the build adds them from the newest windows-engine release)."
        }
        return nil
    }

    /// One line for Diagnostics and the Setup Center.
    static var summary: String {
        if !isBuiltIn { return "not in this build" }
        return "BCD \(version ?? "engine")" + (filesPresent ? "" : " (files missing)")
    }
}
