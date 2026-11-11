import Foundation
import WebKit

/// Per-game web data stores. On iOS 17+ every game gets its own persistent store,
/// so clearing one game never touches another. On iOS 16 all games share the default store.
enum DataStores {
    @MainActor static func store(for game: Game) -> WKWebsiteDataStore {
        if #available(iOS 17.0, *) {
            return WKWebsiteDataStore(forIdentifier: game.id)
        }
        return WKWebsiteDataStore.default()
    }

    @MainActor static func wipe(for game: Game) async {
        if #available(iOS 17.0, *) {
            try? await WKWebsiteDataStore.remove(forIdentifier: game.id)
        } else {
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types)
            let mine = records.filter { $0.displayName == game.host }
            if !mine.isEmpty { await store.removeData(ofTypes: types, for: mine) }
        }
    }
}

struct RestoreResult: Decodable {
    let restoredKeys: Int
    let restoredRecords: Int
    let skipped: [String]
}

enum SaveToolsError: LocalizedError {
    case badResult
    var errorDescription: String? { "The page returned something unexpected." }
}

/// Backs up, restores and clears a game's localStorage and IndexedDB by running JavaScript in its web view.
/// RPG Maker MV keeps saves in localStorage; MZ keeps them in IndexedDB.
enum SaveTools {
    private static let helpers = #"""
    const wrap = (r) => new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const openDB = (name) => new Promise((res, rej) => {
        const r = indexedDB.open(name);
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
        r.onblocked = () => rej(new Error('blocked'));
    });
    const done = (tx) => new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = () => rej(tx.error); tx.onabort = () => rej(tx.error); });
    const listDBs = async () => (indexedDB.databases ? await indexedDB.databases() : []).filter(d => d.name);
    """#

    private static let exportScript = helpers + #"""
    const hasBinary = (v, depth) => {
        if (v instanceof Blob || v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return true;
        if (depth <= 0 || v === null || typeof v !== 'object') return false;
        for (const k of Object.keys(v).slice(0, 50)) { if (hasBinary(v[k], depth - 1)) return true; }
        return false;
    };
    const out = { format: 'nexplay-saves', version: 1, exportedAt: new Date().toISOString(), localStorage: {}, indexedDB: [], binaryRecords: 0 };
    for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); out.localStorage[k] = localStorage.getItem(k); }
    for (const info of await listDBs()) {
        try {
            const db = await openDB(info.name);
            const entry = { name: info.name, version: db.version, stores: [] };
            for (const storeName of Array.from(db.objectStoreNames)) {
                const store = db.transaction(storeName, 'readonly').objectStore(storeName);
                const keys = await wrap(store.getAllKeys());
                const values = await wrap(store.getAll());
                for (const v of values) { if (hasBinary(v, 2)) out.binaryRecords++; }
                entry.stores.push({ name: storeName, keyPath: store.keyPath, autoIncrement: store.autoIncrement, keys, values });
            }
            db.close();
            out.indexedDB.push(entry);
        } catch (e) {
            out.indexedDB.push({ name: info.name, error: String(e) });
        }
    }
    return JSON.stringify(out);
    """#

    private static let restoreScript = helpers + #"""
    const data = JSON.parse(payload);
    if (data.format !== 'nexplay-saves' && data.format !== 'nexhtml-saves') throw new Error('This is not a NexPlay backup file.');
    let restoredKeys = 0, restoredRecords = 0;
    const skipped = [];
    for (const [k, v] of Object.entries(data.localStorage || {})) { localStorage.setItem(k, v); restoredKeys++; }
    const existing = new Set((await listDBs()).map(d => d.name));
    for (const info of (data.indexedDB || [])) {
        if (info.error || !existing.has(info.name)) { skipped.push(info.name); continue; }
        const db = await openDB(info.name);
        for (const s of info.stores) {
            if (!db.objectStoreNames.contains(s.name)) continue;
            const tx = db.transaction(s.name, 'readwrite');
            const store = tx.objectStore(s.name);
            const inline = store.keyPath !== null && store.keyPath !== undefined;
            for (let i = 0; i < s.values.length; i++) {
                if (inline) store.put(s.values[i]); else store.put(s.values[i], s.keys[i]);
                restoredRecords++;
            }
            await done(tx);
        }
        db.close();
    }
    return JSON.stringify({ restoredKeys, restoredRecords, skipped });
    """#

    private static let clearScript = helpers + #"""
    localStorage.clear();
    sessionStorage.clear();
    for (const info of await listDBs()) {
        await new Promise((res) => {
            const r = indexedDB.deleteDatabase(info.name);
            r.onsuccess = res; r.onerror = res; r.onblocked = res;
        });
    }
    return 'ok';
    """#

    @MainActor
    private static func run(_ script: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        guard let string = value as? String else { throw SaveToolsError.badResult }
        return string
    }

    /// Returns the backup file contents and how many IndexedDB records hold binary data that JSON cannot carry.
    @MainActor
    static func exportBackup(from webView: WKWebView) async throws -> (data: Data, binaryRecords: Int) {
        let json = try await run(exportScript, in: webView)
        let data = Data(json.utf8)
        let binary = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["binaryRecords"] as? Int ?? 0
        return (data, binary)
    }

    @MainActor
    static func restore(_ backup: String, into webView: WKWebView) async throws -> RestoreResult {
        let json = try await run(restoreScript, arguments: ["payload": backup], in: webView)
        return try JSONDecoder().decode(RestoreResult.self, from: Data(json.utf8))
    }

    @MainActor
    static func clearAll(in webView: WKWebView) async throws {
        _ = try await run(clearScript, in: webView)
    }

    /// Writes backup data to a temp file with a readable name, ready for the share sheet.
    static func writeBackupFile(_ data: Data, gameName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let safe = gameName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe)-saves-\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
