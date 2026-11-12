import Foundation

// Flash games (.swf) run on Ruffle, the Flash Player emulator written in Rust and WebAssembly
// (https://ruffle.rs, MIT or Apache-2.0). tools/fetch_ruffle.py bundles its self-hosted web build in
// NexPlay.app/Ruffle; the local game server serves it under __ruffle/ next to the game, and a small launcher page
// loads the game's main .swf with it.

enum FlashRuntime {
    /// The bundled Ruffle folder, nil when this build has none.
    static var folder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Ruffle"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("ruffle.js").path) else { return nil }
        return url
    }

    static var version: String? {
        guard let folder else { return nil }
        let text = try? String(contentsOf: folder.appendingPathComponent("VERSION"), encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The game's movie: a .swf named like its folder or "game"/"main", else the largest (preloaders are small).
    static func mainMovie(in root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var movies: [(URL, Int)] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20000 { break }
            guard url.pathExtension.lowercased() == "swf" else { continue }
            movies.append((url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        guard !movies.isEmpty else { return nil }
        let wanted = [root.lastPathComponent.lowercased(), "game", "main"]
        for name in wanted {
            if let hit = movies.first(where: { $0.0.deletingPathExtension().lastPathComponent.lowercased() == name }) { return hit.0 }
        }
        return movies.max { $0.1 < $1.1 }?.0
    }

    /// True when a web page only wraps a Flash movie (an <embed>/<object> of a .swf).
    static func pageEmbedsFlash(_ page: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: page) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 400_000)) ?? Data()
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains(".swf") && (text.contains("<embed") || text.contains("<object") || text.contains("swfobject"))
    }

    enum FlashError: LocalizedError {
        case missing

        var errorDescription: String? {
            "This build of NexPlay has no Flash runtime (Ruffle). Build it again with network access in GitHub Actions."
        }
    }

    /// The page that loads a movie. Paths are URL paths on the local server, percent-encoded.
    static func launcherPage(moviePath: String, title: String) -> Data {
        let movie = PageScripts.jsString("/" + moviePath)
        let directory = (moviePath as NSString).deletingLastPathComponent
        let base = PageScripts.jsString(directory.isEmpty ? "/" : "/" + directory + "/")
        let name = title.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "&", with: "")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <title>\(name)</title>
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #000; touch-action: none; }
        #stage, #stage > * { width: 100%; height: 100%; display: block; }
        #status { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; pointer-events: none;
                  color: #cfc8ff; font: 15px -apple-system, sans-serif; text-align: center; padding: 24px; white-space: pre-line; }
        </style>
        <script>
        window.RufflePlayer = window.RufflePlayer || {};
        window.RufflePlayer.config = {
            publicPath: '/__ruffle/',
            polyfills: false,
            autoplay: 'on',
            unmuteOverlay: 'hidden',
            splashScreen: false,
            letterbox: 'on',
            warnOnUnsupportedContent: false,
            contextMenu: 'off',
            showSwfDownload: false,
            openUrlMode: 'deny',
            allowNetworking: 'all',
            upgradeToHttps: false,
            logLevel: 'warn'
        };
        </script>
        <script src="/__ruffle/ruffle.js"></script>
        </head>
        <body>
        <div id="stage"></div>
        <div id="status">Starting Flash…</div>
        <script>
        (function () {
            var status = document.getElementById('status');
            function fail(err) {
                var message = err && err.message ? err.message : String(err);
                console.error('Flash could not start: ' + message);
                status.textContent = 'Flash could not start:\\n' + message;
            }
            try {
                var ruffle = window.RufflePlayer.newest();
                var player = ruffle.createPlayer();
                player.setAttribute('tabindex', '0');
                document.getElementById('stage').appendChild(player);
                var api = (typeof player.ruffle === 'function') ? player.ruffle() : player;
                var done = api.load({ url: \(movie), base: \(base) });
                var ready = function () { status.style.display = 'none'; try { player.focus(); } catch (e) {} };
                if (done && typeof done.then === 'function') { done.then(ready, fail); } else { ready(); }
                player.addEventListener('pointerdown', function () { try { player.focus(); } catch (e) {} });
            } catch (err) {
                fail(err);
            }
        })();
        </script>
        </body></html>
        """
        return Data(html.utf8)
    }
}
