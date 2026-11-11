# NexPlay 2.0.0 spec (one-shot build)

For the AI that builds NexPlay 2.0.0 in one run. Read CLAUDE.md first, then this whole file, then `docs/RESEARCH.md` (what the reference apps do), then start. Do all parts A to H in order without waiting for the owner. Version 1.1.x is the current state; the finished result is 2.0.0.

## 1. Product
NexPlay is a personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+), and in 2.0.0 also RPG Maker XP/VX/Ace (mkxp-z core, flag-gated). It is not a web browser: everything in it is a game. One user (the owner), sideloaded, never on the App Store.
Goals in order: games run correctly, saves are never lost, controls feel good on a phone, the library is pleasant.
Non-goals: browsing, ads, accounts, analytics, App Store rules, Mac/iPad polish, Ren'Py/Unity/Wolf RPG.

## 2. How this run works
- The owner has only an iPhone. GitHub Actions builds an unsigned IPA on every push to main. Claude cannot compile Swift. If the build fails, the owner pastes the red lines in a later chat; until then you cannot see errors. So the code must compile the first time: see section 5.
- Work in parts A to H (section 6). Push one commit per part to `main`. Each push bumps the version in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`): A 1.1.4 build 6; B 1.2.0 build 7; C 1.3.0 build 8; D 1.4.0 build 9; E 1.5.0 build 10; F 1.6.0 build 11; G 1.9.0 build 12; H 2.0.0 build 13.
- Each push triggers a build, so a later part failing to compile must never hide an earlier one: keep parts additive and independent where possible.
- Workflow files (`.github/workflows/*`) cannot be pushed by you. Part G needs a workflow change: put the full file in `docs/workflow-2.0.0.yml` AND print it in your final message for the owner to paste as `.github/workflows/build.yml`.
- Budget: you cannot do everything perfectly. Every item below is tagged P0 (must), P1 (should), P2 (nice). Finish all P0 of every part first. Then add P1 items. Do P2 only if there is room. When you skip an item, list it in CLAUDE.md under "Not built" with the reason, and mention it in the final message. A smaller app that compiles beats a bigger one that does not.
- Your final message to the owner (short): what was built per part, what you skipped and why, the workflow file if it changed, and the device test checklist from section 8.
- Update CLAUDE.md (layout, rules) and tick the parts below in the same commits.

## 3. Standing permission: look things up and copy
The owner allows you to read and copy from Empo and other sources without asking, and wants you to keep researching: the reference apps have more than this spec lists.
- At the start of each part, re-read the matching Empo files and docs (section 4), and search GitHub (`search_code`) and the web for how other projects solved the same problem. Prefer a proven solution to an invented one.
- Sources: Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile (all mateo-m), mkxp-z, EasyRPG, JoiPlay, libretro mkxp-z docs, and any other open-source project with a permissive or GPL-compatible license.
- Licenses: Empo and its cores are GPL-3.0-only with additional terms. Copying into this private app is allowed. Keep a header comment with copyright and source URL in every file with copied or closely adapted code, and list every source in Settings > Credits. Never name the app "Empo", never use its icon, logo or strings, never claim its code. If a repo has no license, or a closed one, do not copy code: use ideas only. RPGPlayer, ArkRPG, Runa, QuestPlay, RPGEmu are closed: ideas yes, assets, names and text no.
- If Empo's way conflicts with a NexPlay rule (it disables the Gamepad API; NexPlay uses it), keep the NexPlay rule and note it in CLAUDE.md.
- Empo is Objective-C/SwiftUI for iOS 26 and uses iOS 26-only APIs (glass effects, `@Observable`, `Group(subviews:)`): adapt down to iOS 16 or skip. Never copy such calls as they are.

## 4. Reference map (Empo, branch main)
| Topic | Where |
|---|---|
| MV/MZ runtime: NW.js shim, fs over XHR, frames, pause, speed, keys | `mvmz-apple-mobile/src/runtime.js` |
| MV/MZ web view setup, user agent, delegates | `mvmz-apple-mobile/src/mvmz_core.m` |
| File server: PUT/DELETE/MKCOL/MOVE/HEAD, case-insensitive, ranges | `mvmz-apple-mobile/src/MvmzFileServer.m` |
| Placing the game view, safe area, portrait position, snapshot on pause | `cores/mvmz/mvmz_app_bridge.m`, `ios/Empo/docs/pause-resume.md` |
| Controls model, layout, grid snap, per-orientation profiles | `ios/Empo/src/Player/ControlsLayout.swift`, `ControlsLayout+GridSnap.swift`, `ControlsZoneGeometry.swift`, `LayoutProfilesManager.swift`, `LayoutProfileViews.swift`, `UserControlsFile.swift`, `docs/controls-format.md` |
| Control editing, touch capture | `ControlsEditModifier.swift`, `ControlTouchCapture.swift`, `GameControls.swift`, `PlayerControlsOverlay.swift` |
| Physical controllers and bindings | `GameControllerReader.swift`, `ControllerInputManager.swift`, `BindingStore.swift`, `BindingsCatalog.swift`, `BindingsView.swift`, `KeyboardInputManager.swift` |
| Soft keyboard bar for games that ask for typing | `KeyboardAccessoryBar.swift`, `KeyboardFieldRepresentable.swift`, `TCKeyboardField.mm` |
| Toolbar, more sheet, runtime state, debug overlay, screen placement | `PlayerToolbar.swift`, `PlayerMoreSheet.swift`, `PlayerRuntimeState.swift`, `DebugOverlayView.swift`, `ScreenRegionApplier.swift`, `ScreenRegionGizmo.swift`, `PlayerView.swift` |
| Import pipeline | `ios/Empo/docs/import-pipeline.md`, `ios/Empo/src/Library/ImportPipeline.swift`, `GameImportValidator.swift`, `ArchiveExtractor.swift`, `GameImporter.swift`, `Jgp.swift`, `DocumentPickerView.swift`, `ImportRootPickerSheet.swift` |
| Library views, cards, sort, search, info | `GameLibraryView.swift`, `GameCard.swift`, `GameHeroCard.swift`, `GameInfoView.swift`, `GameSorting.swift`, `LibrarySortSheet.swift`, `LibrarySearchBar.swift`, `GameContextMenu.swift`, `GameArtworkView.swift`, `ImageCache.swift` |
| Per-game settings | `GameSettings.swift` (restart vs runtime flag idea), `GameSettingsSections.swift`, `GameSettingsView.swift` |
| Saves safety | `SaveMigration.swift`, `SaveRecoverySheet.swift`, `docs/saves.mdx`, `ios/Empo/src/Backup/GameSaveWatch.swift` |
| Backups | `docs/backups.mdx`, `ios/Empo/src/Backup/` (`BackupPass.swift`, `GameBackupSets.swift`, `Restore/`, `Scheduling/`, `Package/`, `UI/`) |
| App settings, theme, language, what's new, hints | `ios/Empo/src/App/AppSettings.swift`, `ios/Empo/src/Settings/*`, `ios/Empo/src/Library/WhatsNewSheet.swift`, `ios/Empo/src/Hints/*` |
| Crash and error logging | `ios/Empo/src/App/CrashTracker.swift`, `SessionLogger.swift`, `ErrorReports.swift` |
| mkxp-z core pattern | `cores/mkxp`, `cores/cores.sh`, `cores/framework-common.sh`, `cores/GameCore.h`, `cores/gamecore.exports`, `ios/Empo/docs/cores.md`, `multi-ruby.md`, `multi-session.md`, `ios/Empo/src/Cores`, `ios/Empo/src/App/AppCoreForwarders.c`, `ios/Empo/project.yml` |
| Troubleshooting knowledge | `docs/troubleshooting.mdx`, `docs/faq.mdx`, `docs/playing.mdx` |

## 5. Writing Swift that compiles first time
Nothing is compiled before you push. Treat every file as if a single error fails the whole build.
- Before pushing each part, re-read every changed or new file top to bottom and check: imports (`UIKit`, `SwiftUI`, `WebKit`, `GameController`, `LocalAuthentication`, `Combine`, `ZIPFoundation`, `AVFoundation`, `Photos`, `UniformTypeIdentifiers`); argument labels of every call; `self.` in escaping closures inside classes; `@MainActor` on UI and WKWebView code and `Task { @MainActor in }` where needed; optional unwrapping; `let` vs `var`; exhaustive `switch` (grep every `switch` on an enum you extended); every type you use exists (grep the repo); no duplicate type names; protocol conformances complete; Codable keys.
- Use only APIs that exist on iOS 16. Newer APIs (`WKWebsiteDataStore(forIdentifier:)` iOS 17, `Translation` iOS 18, `@Observable` iOS 17, `ContentUnavailableView` iOS 17, `scrollContentBackground` iOS 16 ok, `NavigationStack` iOS 16 ok) go behind `#available` with a fallback, or are avoided. Use `ObservableObject` and `@Published`, not `@Observable`.
- Prefer simple UIKit/SwiftUI code. No new packages except what archive import needs. No Objective-C bridging header unless Part G needs it.
- Settings keys go in `SettingsKey` (Models.swift) and defaults in `NexPlayApp.init` registration.
- New `Game` fields are optional or defaulted. Change games only via `store.mutate(id)`.
- New files are picked up automatically: `project.yml` has `sources: - path: NexPlay`.
- Info.plist: read the file, add keys, keep it valid XML.
- Put logic that can be a plain JS string in JS you can read once more, not in clever Swift.
- After each push you cannot see CI. So do a second review pass on the riskiest file of the part before moving on.

## 6. Parts
Tags: P0 must, P1 should, P2 nice.

### Part A (1.1.4): Base check
- P0: Read every Swift file, `Info.plist`, `tools/make_icon.py`, `project.yml`, `docs/`. Fix real bugs you see (not style). Check `LibraryStore` deletes a game's folder and data store, imports ZIP/folder/HTML, and that `GameDetailView` and `LibraryView` compile against the current `Game`.
- P1: add an app-wide `AppLog` (ring buffer + file in Caches, share button) next to `GameLog`, used for import, backup and crash notes; used by the Diagnostics row in D.
- P1: crash note: on launch, if the previous session did not end cleanly (flag in UserDefaults set at start, cleared at background/exit), log it to `AppLog` (idea from Empo `CrashTracker.swift`).
- Push if you changed anything; otherwise skip the push and start version numbering at B (1.2.0 build 7 stays).

### Part B (1.2.0): NW.js shim, file-based saves, save safety
Scope:
- P0 `NexSchemeHandler`: add PUT, DELETE, MKCOL, MOVE, HEAD, and directory listing (GET on a directory with header `X-Nex-List: 1` returns a JSON array of names, otherwise it serves `index.html` as now). Response headers: `X-Nex-Kind` (`file`/`directory`), `X-Nex-Mtime` (ms). The game root itself is read-only. All writes stay inside the game folder, atomic (`.atomic`), create intermediate directories. Request bodies arrive in `request.httpBody` (if nil, also read `httpBodyStream`).
- P0 `PageScripts.nwShim` for RPG Maker games, adapted from `runtime.js`: `window.require` (`fs`, `path`, `os`, `nw.gui`), `window.nw`, `window.process` (`cwd()` returns `/`, `platform` `linux`, `mainModule`, `versions`, `env`, `argv`, `exit`, `on`), sync XHR fs (`existsSync`, `statSync`, `lstatSync`, `readFileSync` text and binary, `writeFileSync` text and `Uint8Array`/`ArrayBuffer`, `unlinkSync`, `mkdirSync`, `readdirSync`, `renameSync`, `rmdirSync`), callback versions run one tick later, `nw.gui.Window.get()` returns a Proxy of no-ops, `window.close` and `nw.App.quit` post an exit message that the app handles by leaving the game. Also stub `process.versions`, `os.homedir`, `os.tmpdir`.
- P0 Setting `nwMode` (default true) in Settings > RPG Maker games; per-game override `Game.nwMode: Bool?`. Inject the shim only when on. Result: `Utils.isNwjs()` is true, so MV/MZ keep saves as files (`save/…`) inside the game folder instead of localStorage/IndexedDB.
- P0 Save migration when nwMode turns on for a game that has browser-mode saves: JS in `SaveTools` that reads MV localStorage keys (`RPG Global`, `RPG File<N>`, `RPG Config`) and MZ IndexedDB records and writes them as files MV: `save/global.rpgsave`, `save/file<N>.rpgsave`, `save/config.rpgsave`; MZ: `save/config.rmmzsave`, `global.rmmzsave`, `file<N>.rmmzsave` (content is the string the engine already stored: write unchanged). Run once per game (`Game.savesMigrated: Bool?`). Never delete old data. One log line per file. If a record is binary or unknown, skip and log.
- P0 Backup/restore for nwMode games: zip the game's `save/` folder with ZIPFoundation (`<Name>-saves-<date>.zip`) and share; restore picks a zip, confirms with the game's name, backs the current `save/` up to `Backups/<game>/before-restore-<date>.zip`, then extracts. A file that would be replaced gets the old copy kept as `<name>.nex-displaced.bak` (Empo convention). Keep the JSON tool for browser-mode and HTML5 games. The player menu "Saves" picks the right tool.
- P0 Delete game rescues saves: deleting a game moves `save/` into `Application Support/NexPlay/Rescued Saves/<name>-<uuid>/` first; re-importing the same title offers to put them back. (Empo: `docs/saves.mdx`, `SaveMigration.swift`.)
- P1 Game detail sheet: save count, size, last save date; Export, Import, Delete Saves (confirmation naming the game).
- P1 Save recovery sheet idea: on launch, if a `save/` file exists with a `.nex-displaced.bak`, show a list in the detail sheet.
- P1 Expose the data folder in the Files app: `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in Info.plist and a "Show in Files" row in Settings (`UIApplication.shared.open(URL(string: "shareddocuments://" + documentsPath)!)`). Only if the data directory can sit in Documents without breaking existing libraries: decide, then document in CLAUDE.md. If it would require moving existing games, skip.
- P1 `$userAgentVersion`-style identity: expose `window.nexplay = { version }` to games.
Acceptance: save, force-quit, reopen: save still there. Export zip, delete saves, import: save returns. A plugin that calls `require('fs')` starts. Deleting and re-importing a game offers the rescued saves.

### Part C (1.3.0): Controls
- P0 Model (`ControlsLayout.swift`): control kinds `dpad` (4/8-way), `joystick` (style option for movement), `confirm`, `cancel`, `menu`, `dash`, `pageUp`, `pageDown`, `fastForward`, `custom(keyCode)`; each has normalized center (x, y in 0...1), size, opacity, visibility, label. Max 21 controls per orientation. A layout is a list. A `LayoutProfile` has a name, a portrait layout and a landscape layout.
- P0 Storage (`LayoutStore`): JSON in Application Support: `Layouts/default.json`, `Layouts/<game-uuid>.json`; a game with no file follows the default profile. Resolution chain "Automatic": game `controls.json` (P2) → game layout → default profile → built-in default. Actions: save, reset, copy to default, copy default to game.
- P0 Overlay (`GamepadOverlay.swift` extended): multi-touch, press on touch-down (not touch-up), release on touch end/cancel, 8-sector direction with dead zone for D-pad and joystick, refcount held keys so two controls on one key release correctly (Empo bug fix). Haptics (`UIImpactFeedbackGenerator`; setting `hapticsEnabled` default true, strength).
- P0 Edit mode from the game menu: drag, resize (pinch or slider), opacity slider, label, delete, add (choose an action or a key), grid snap toggle, undo last change, reset, Done. Saved per orientation.
- P0 Hide/show controls toggle (menu + control bar).
- P0 Physical controllers: `PhysicalControllerManager` using `GCController` (`extendedGamepad`, also `microGamepad` basic) sends keys through `__nexKey`; default map A=OK, B=cancel, X=menu, Y=dash, L1/R1=page up/down, D-pad and left stick (eight sectors) = arrows. Remap screen in Settings > Controls and in the game menu with scope "This game" / "All games", storing `[button: PadKey]` as JSON. Default `controllerMode` = `keys`; `gamepadAPI` mode leaves the Gamepad API alone. Never override `navigator.getGamepads`.
- P1 Control bar: optional bar (setting `controlBar`, default off) with fast-forward, menu, restart, hide controls, screenshot, keyboard.
- P1 Show keyboard: a hidden `UITextField` that sends typed characters and Backspace/Enter as key events through `__nexKey` for games that need typing (idea: Empo `KeyboardAccessoryBar`, RPGEmu virtual keyboard). MV/MZ text-input plugins already get a real keyboard from WebKit when the page focuses an `<input>`: only add the key-sender for games that read raw key events.
- P1 Fast-forward as a bindable action (controller button and on-screen button), 2 to 9x slider in per-game settings, resets when a new game starts.
- P1 Portrait position: per-game `portraitAlignment` (top, center) via web view constraints; page reports `Graphics.width/height` through a `nexSize` message from the runtime script (it already polls frames) to size the view to the game's aspect ratio; free area below holds controls.
- P1 Screenshot: `webView.takeSnapshot` then save to Photos (`NSPhotoLibraryAddUsageDescription`).
- P1 "Fill unused screen area" colour setting (Empo has it) and sharp-pixels per game override.
- P2 Pause snapshot: when leaving to the library mid-game, keep the web view alive and show a snapshot (`takeSnapshot`) card with "Continue"; MV/MZ only. Read `pause-resume.md`.
- P2 Game-shipped `controls.json` (read Empo `docs/controls-format.md`) and JoiPlay `gamepad.json` translation.
- P2 Drag/resize the game screen in edit mode (screen placement).
Acceptance: move and resize the D-pad in portrait and landscape, quit and reopen: layout stays. Haptic on press. Two fingers work (move and confirm at once). A controller moves the hero and opens the menu.

### Part D (1.4.0): Library, privacy, backups, settings, plugins, cheats
- P0 Library: grid and list layouts (`libraryLayout`), search, 10 sort options like Empo (title A-Z/Z-A, recently/least recently added, recently/least recently played, most/least played, largest/smallest) in a sort sheet, engine filter chips (MV, MZ, HTML, later Ruby), empty state with import hint, title position (inside/under) for grid, "Continue playing" card with the last game (setting).
- P0 Collections: `Collection { id, name, color, gameIDs, isHidden }` in `Collections.json`; create, rename, recolour, delete, add/remove games (context menu and detail sheet), chips at the top, drag to reorder games and collections (`onMove`/`onDrag` in SwiftUI list; grid reorder only if simple, otherwise list-only).
- P0 Select multiple + bulk delete with confirmation; context menu on a card: Info, Settings, Select multiple, Delete.
- P0 Privacy: `PrivacyLock` with `LocalAuthentication` (`.deviceOwnerAuthentication`); games and collections can be hidden; unlock via a lock button; stays unlocked until the app backgrounds; `NSFaceIDUsageDescription`. `Game.isHidden: Bool?`.
- P0 Auto backups: `AutoBackup` zips each nwMode game's `save/` into `Backups/<game-uuid>/<yyyy-MM-dd-HHmmss>.zip` when a session ends, when the app backgrounds, and 30 s after launch, only if saves changed (newest mtime). Retention presets like Empo: Less (last 5), Standard (last 10), More (last 20). Detail sheet lists backups, restore with confirmation (current saves kept as `.nex-displaced.bak`). "Back up now" and "Export all saves" (one zip of every game's `save/`). Opening a NexPlay backup `.zip` from Files imports it (`onOpenURL`, offer which game).
- P0 Settings rebuilt (SwiftUI): search field filters rows; grouped sections with coloured icon tiles; Appearance (theme dark/light/system, accent colour, library layout, title position, library background plain/gradient/image, alternate app icon P1), Controls (haptics, control bar, controller mode, remap), Gameplay & Performance (default orientation, desktop mode, sharp pixels, NW.js mode, keep awake, silent-mode audio, portrait alignment default), Privacy, Import & Backup (retention, media conversion, backups location, Show in Files), Translation (F), Advanced (Diagnostics overlay, game log, app log share, "delete broken imports", debug logs with keep-last-N), About (version, credits, What's New, Show Tips Again), Reset to Defaults (confirmation, keeps games).
- P1 Per-game settings sheet (long-press card > Settings): orientation, desktop mode, sharp pixels, NW.js mode, fast-forward speed, block network, controller mode, portrait alignment, "Changed by you" marker and "Reset to default" per row, "Reset all" (idea: Empo `GameSettings.swift`, `GameSettingsSections.swift`). Mark restart-required settings and show a hint when changed during a session.
- P1 Game info sheet: engine and version (MV/MZ from `Utils.RPGMAKER_VERSION` or `package.json`), size, location, save count, play time, play count, last played, date added; edit name, version, cover image (pick from Photos/Files; default `icon/icon.png`, then title image from `img/titles1`).
- P1 Storage manager: per-game size list with total, sorted by size, delete from there; "Invalidate missing games" (remove entries whose folder is gone; JoiPlay idea).
- P1 Plugin manager for MV/MZ: parse `js/plugins.js`, list plugins with on/off toggles, store overrides in `PluginOverrides/<game-uuid>.json`, and have `NexSchemeHandler` serve a generated `js/plugins.js` when overrides exist (never edit the game's file). Warn that disabling plugins can break a game. (RPGPlayer and JoiPlay both offer this.)
- P1 Cheat menu for MV/MZ (RPGPlayer/JoiPlay/Empo have one): game menu > Cheats opens a sheet that calls JS: add gold, give item/weapon/armor by id, heal party, god mode, walk through walls (`$gamePlayer.setThrough`), disable encounters, set switches/variables by id, speed. Implement in a JS string `PageScripts.cheats` exposing `window.__nexCheat(name, value)`. Off by default per game; guard every call with typeof checks.
- P1 Gamepad UI navigation in the library (RPGPlayer 2.3): D-pad/stick moves focus, A opens, B back. Use `GCController` handlers to drive SwiftUI focus (`@FocusState`/`.focusable`, iOS 17 for some APIs: gate and skip on iOS 16).
- P1 What's New sheet (one-time after update, from a bundled JSON) and Tips (first-run hints, `Show Tips Again`).
- P1 Alternate app icons: 2 or 3 alternates from `tools/make_icon.py` with a style argument, `CFBundleAlternateIcons` in Info.plist. If CI icon generation cannot be extended safely, ship only the default and say so.
- P2 WebDAV backup target (read Empo `Providers/WebDAV*.swift`): URL, user, app password, upload zips; skip Dropbox/Drive/S3/iCloud (need OAuth, Plus, or entitlements a self-signed IPA lacks).
- P2 Localization: String Catalog with a few languages and a language picker (Empo: 9 languages).
- P2 iPad widgets (RPGPlayer): needs a widget extension target: skip.
Acceptance: collection hidden behind Face ID; a backup appears after a session; plugin toggled off changes the game; cheat gives gold; Reset to Defaults restores settings.

### Part E (1.5.0): Import and media
- P0 Import pipeline hardening (read `import-pipeline.md` fully; copy the invariants): zip-slip defense by path components (not by filesystem-prefix compare), cancellation checked in every long phase, out-of-space error mapped to a clear message, in-flight guard so a card never shows a half-imported game, one atomic move into place, progress card in the library with cancel, files picked with `asCopy: true`, temp staging deleted afterwards.
- P0 Update in place: importing a game whose title matches an installed game offers **Update**: merge new files over a staged copy, swap atomically, keep `save/` and settings; a same-path file in the import that collides with a save is archived as `.nex-displaced.bak`. Never delete the installed game on failure. (Empo `GameImporter.stageAndSwapGameTree`, `SaveMigration`.)
- P0 Encoding: ZIP entry names in GBK/Shift-JIS/CP437 are common (RPGPlayer 13 language families, ArkRPG GBK/Shift-JIS): detect mojibake and re-decode filenames; decode `Game.ini`/`System.json` titles with a fallback to CP1252/Shift-JIS. ZIPFoundation gives raw entry bytes; if its API does not allow raw names, implement the fallback or skip with a note.
- P0 Import `.7z`, `.rar` and self-extracting `.exe`: Empo uses libarchive (+ libmspack for CAB sfx). Find how it is vendored (`ios/Empo/vendor`, `project.yml`), copy the build recipe if it builds in CI without a Mac; check licenses. If nothing is safely buildable, keep the clear error message and say so in the final message.
- P0 Warnings in the import summary: no `index.html`, RTP required (XP/VX/Ace without RTP assets), encrypted/odd assets, games that need Windows-only features.
- P1 Multi-root picker when an archive holds several games (Add Games vs Already in Library steps, Empo `ImportRootPickerSheet`).
- P1 Media conversion setting (`convertMedia`, default off): for MV/MZ when OGG will not play on this device, convert `.ogg` to `.m4a` with `AVAssetExportSession`/`AVAudioFile` only if AVFoundation can read it; never touch originals; log what was skipped. MV falls back to `.m4a` when `canPlayOgg` is false.
- P1 Detect XP/VX/Ace (`Game.ini`, `Data/Scripts.rxdata|rvdata|rvdata2`, `RGSS*.dll`) and add `GameEngine` cases `rpgXP`, `rpgVX`, `rpgVXAce`; `isRPGMaker` stays for MV/MZ; add `isRuby`. Keep every `switch` exhaustive. Library shows an engine badge and "needs mkxp core" until G is enabled.
- P2 `.jgp` JoiPlay packages (Empo `Jgp.swift`), EXE icon extraction for covers (`ExecutableIconExtractor.swift`), Enigma Virtual Box exe, duplicate-title folder handling.

### Part F (1.6.0): Translation
- P0 Settings: `translationEnabled` (default off), `translationTarget`, per-game override. RPG Maker MV/MZ only.
- P0 MTool translation file support (ArkRPG): per-game dictionary file `TranslateFile.json` (a JSON object mapping source text to translated text) placed in the game's folder or imported from Files; applied offline by the JS hook. No network, works on every iOS version.
- P0 JS hook (`PageScripts.translate`): wrap `Window_Base.prototype.drawTextEx`, `Window_Message` text conversion (`convertEscapeCharacters`), `Bitmap.prototype.drawText` for UI labels; look each string up in the dictionary/cache; unknown strings are posted to the app (`nexTranslate` message handler) and shown untranslated; when a translation arrives, refresh the window. Translate only the text segments between escape codes (`\C[2]`, `\V[1]`).
- P1 Apple on-device translation with `#available(iOS 18.0, *)` (`Translation` framework needs a SwiftUI host view with `.translationTask`; host a hidden one). Per-game cache `Translations/<game-uuid>.json`. On older iOS the setting explains it needs iOS 18 and the MTool path still works. Never send text to an online service.
- P1 Settings > Translation: enable, target language, import dictionary, export collected untranslated strings as JSON (so the owner can translate them elsewhere and re-import), clear cache.
Acceptance: with an MTool file, dialogue shows translated. On iOS 18 untranslated dialogue is translated after a short delay and cached.

### Part G (1.9.0): RPG Maker XP/VX/Ace (mkxp-z), behind a flag
The core is large and cannot be tested here, so isolate it so main always builds:
- P0 Add a compilation flag `NEXPLAY_MKXP` (project.yml `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `GCC_PREPROCESSOR_DEFINITIONS`), OFF by default. All core code lives in `NexPlay/MKXP/` wrapped in `#if NEXPLAY_MKXP`; the rest of the app talks to a small protocol `RubyGameRunner` with a stub implementation that says "This build has no mkxp core" when the flag is off.
- P0 Read Empo's `cores/mkxp/*`, `cores/cores.sh`, `cores/framework-common.sh`, `cores/GameCore.h`, `cores/gamecore.exports`, `ios/Empo/docs/cores.md`, `multi-ruby.md`, `multi-session.md`, `ios/Empo/src/Cores`, `AppCoreForwarders.c`, and the `GameCore.h` contract (it is the one interface every core implements). Copy the pattern: pinned release + SHA-256 in a `.version` file, a fetch script (`tools/fetch_mkxp_core.sh`) that downloads the prebuilt core tarball in CI, header include path and static library linked into the app, a small bridge that calls `gamecore_*` (set game path, run, inject key, pause/resume, snapshot, FPS, session config) and embeds the SDL/Metal window in a `UIViewController`.
- P0 Write `docs/workflow-2.0.0.yml`: the existing build workflow plus a step that runs the fetch script before `xcodegen generate` and passes the flag to `xcodebuild`. Tell the owner to paste it as `.github/workflows/build.yml` ONLY after the flag-off build passes, and how to switch the flag on.
- P0 Player for `isRuby` games: reuse the controls overlay and controller manager from Part C to feed `gamecore_injectKeyEvent`; show "close and reopen the app to start another Ruby game" after quitting (one Ruby game per launch, like Empo: `multi-session.md`).
- P1 Per-game Ruby-core settings from Empo: smooth scaling, fixed aspect ratio, frame skip, font scale, solid fonts, postload scripts, path cache, in-game keyboard, touch acts as mouse (XP games), JoiPlay compatibility, network access; use the "restart vs runtime" flag idea. Warn about RTP games (`docs/troubleshooting.mdx`). MIDI: Empo bundles a SoundFont and lets the user import `.sf2`/`gm.dls`: P2.
- P1 Known limits to show in the UI: Ogg/Theora movies only; some Windows-only DLL calls fail.
- P1 Credits: mkxp-z (GPLv2+), Empo cores (GPLv3), Ruby, SDL, ANGLE, FluidSynth as Empo's `licenses.json` lists.
Acceptance (after the owner turns the flag on): an XP or Ace game starts, takes input, plays sound, saves. If the core cannot be linked reliably from CI, leave the flag off and say exactly what is missing.

### Part H (2.0.0): Finish
- Version 2.0.0 build 13. Update CLAUDE.md (layout, rules, roadmap, what is flag-gated, Not built list), tick this file, update `docs/PROMPT.md` if needed, update Settings > Credits with every source used.
- Final self-review of all new files for section 5 errors; fix what you find and push.
- Final message as described in section 2.

## 7. Cross-cutting requirements
- Never lose a save: atomic writes, back up before migrating, restoring or importing over a game; confirm before deleting and name the game; deleting a game rescues its saves first.
- NexPlay itself uses no network. Games may use it unless `blockNetwork` is on. No analytics, no error reporting to anyone.
- Data lives in Application Support/NexPlay (Games, Layouts, Backups, Translations, PluginOverrides, Rescued Saves, Collections.json). Deleting a game removes its folder, data store, layout and backups only after confirmation.
- Nothing heavy on the main thread: import, backup, zip, scan run in `Task` with progress. Decode cover images off the main thread and cache them.
- Dynamic Type in SwiftUI screens; accessibility labels on icon buttons.
- Use `GameLog` for game problems and `AppLog` for app problems; both shareable.
- Web content process killed (out of memory): log it, reload, and tell the user once (ArkRPG and RPGPlayer users hit this: large MV/MZ games).

## 8. Device test checklist (the owner runs this after the build)
1. App launches, library shows, an MV game and an MZ game start.
2. Sound plays (also with the silent switch on).
3. Touch controls work; edit mode moves and resizes; layout survives a restart. A controller works if available.
4. Save, quit the app completely, reopen, load: the save is there. Export saves, delete, import: back. Delete a game, re-import: offered the rescued saves.
5. Rotate, fast-forward x2/x4, leave and return: no freeze, no sound burst.
6. Create a collection, hide it, relaunch: asks for Face ID.
7. A backup zip appears after a session; restore works.
8. Plugins sheet toggles a plugin; cheat menu gives gold.
9. Import a `.7z` or `.rar` (if Part E shipped it) and a ZIP with Japanese or Chinese file names.
10. MTool translation file or iOS 18 translation (if available).
11. Game Log shows no repeating errors. If something fails, share the log from the game menu and paste the Actions red lines if the build failed.

## 9. Open questions (decide by sensible default, note in CLAUDE.md)
- Does OGG play on the owner's phone without conversion? Default: conversion off (Empo treats it as a simulator-only problem).
- Does desktop mode break touch in any game? Default: on, with the setting to turn it off.
- iCloud sync of saves and iCloud Drive/Dropbox/Drive/S3 backups: not built (a self-signed IPA probably lacks the entitlement, the others need OAuth or accounts). Files-app export and WebDAV (P2) instead.
- The repo is private, so an in-app update checker cannot read releases: skip.

## 10. Engines roadmap (owner, 2026-11-11)
Definitely coming: RPG Maker MV/MZ (done), RPG Maker XP/VX/VX Ace (mkxp-z, Part G), Godot, Ren'Py. Maybe: Construct, Twine, TyranoBuilder.
Notes for whoever builds them (unverified, check before starting):
- Construct 2/3, Twine (Harlowe/SugarCube/Snowman) and TyranoBuilder/TyranoScript export HTML5; they already run as "HTML5 game". Work: detect them (Construct: `c3runtime.js`/`c2runtime.js`, `data.json`; Twine: one HTML with `<tw-storydata>`; Tyrano: `tyrano/` folder + `data/scenario/`) and give each its own `GameEngine` case and badge, save handling (Twine and Tyrano save to localStorage) and a per-engine key map.
- Godot web exports: Godot 3 runs in WKWebView with WebGL. Godot 4 needs SharedArrayBuffer (cross-origin isolation: COOP/COEP headers) unless exported single-threaded (4.3+ "Thread Support" off); the scheme handler would add `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, and whether WKWebView grants isolation on a custom scheme must be tested. Desktop Godot exports (.pck + .exe) need a native Godot iOS runtime that loads a `.pck`: large, separate phase (export templates for iOS are built per project).
- Ren'Py: desktop builds are Python + SDL; on iOS the realistic path is the Ren'Py web build (renpyweb, WebAssembly) running the game's `game/` folder, or a native Ren'Py iOS runtime. Both are large; research first.
Every new engine: keep `switch` on `GameEngine` exhaustive, add detection in `GameScanner`/`ImportPipeline`, import warnings, a badge, controls defaults, and save rescue rules.

Status 3.0.0: Godot Web exports, Construct, Twine and TyranoScript are detected and run (Godot through the loopback server with COOP/COEP). Still open: Godot desktop builds (.pck/.exe) would need a matching Godot web runtime per engine version; Ren'Py not started.
