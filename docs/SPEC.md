# NexPlay 2.0.0 spec (one-shot build)

For the AI that builds NexPlay 2.0.0 in one run. Read CLAUDE.md first, then this whole file, then start. Do all parts A to H in order without waiting for the owner. Version 1.1.x is the current state; the finished result is 2.0.0.

## 1. Product
NexPlay is a personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+), and in 2.0.0 also RPG Maker XP/VX/Ace (mkxp-z core). It is not a web browser: everything in it is a game. One user (the owner), sideloaded, never on the App Store.
Goals in order: games run correctly, saves are never lost, controls feel good on a phone, the library is pleasant.
Non-goals: browsing, ads, accounts, analytics, App Store rules, Mac/iPad polish.

## 2. How this run works
- The owner has only an iPhone. GitHub Actions builds an unsigned IPA on every push to main. Claude cannot compile Swift. If the build fails, the owner pastes the red lines in a later chat; until then you cannot see errors. So the code must compile the first time: see section 5.
- Work in parts A to H (section 6). Push one commit per part to `main`. Each push bumps the version (A: 1.1.3 build 5; B: 1.2.0 build 6; C: 1.3.0 build 7; D: 1.4.0 build 8; E: 1.5.0 build 9; F: 1.6.0 build 10; G: 1.9.0 build 11; H: 2.0.0 build 12). `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.yml`.
- Because each push triggers a build, a later part failing to compile must never hide an earlier part: keep parts independent and additive.
- Workflow files (`.github/workflows/*`) cannot be pushed by you. Part G needs a workflow change: put the full file in `docs/workflow-2.0.0.yml` AND print it in your final message for the owner to paste as `.github/workflows/build.yml`.
- Your final message to the owner (short): what was built per part, anything you skipped and why, the workflow file if changed, and the device test checklist from section 8.
- Update CLAUDE.md (layout, rules) and tick the parts below in the same commits.

## 3. Standing permission: look things up and copy
The owner allows you to read and copy from Empo and other sources without asking.
- Sources: Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile (all mateo-m), mkxp-z, EasyRPG, JoiPlay, and any other open-source project with a permissive or GPL-compatible license. Use `search_code`, `get_file_contents`, and web search.
- Licenses: Empo and its cores are GPL-3.0-only with additional terms. Copying into this private app is allowed. Keep a header comment with copyright and source URL in every file with copied or closely adapted code, and list every source in Settings > Credits. Never name the app "Empo", never use its icon, logo or strings, never claim its code. If a repo has no license, or a closed one, do not copy code: use ideas only. RPGPlayer is closed (the owner's screenshots only): ideas yes, assets, names and text no.
- Before designing a part, read Empo's matching doc in `ios/Empo/docs/` (`import-pipeline.md`, `pause-resume.md`, `design-system.md`, `cores.md`, `multi-ruby.md`, `multi-session.md`) and the code in the reference map (section 4).
- If Empo's way conflicts with a NexPlay rule (it disables the Gamepad API; NexPlay uses it), keep the NexPlay rule and note it in CLAUDE.md.
- Prefer adapting Empo's code over inventing. Empo is Objective-C/SwiftUI for iOS 26; NexPlay targets iOS 16 with UIKit player + SwiftUI screens: adapt APIs down (no iOS 17+/26-only API without `#available` and a fallback).

## 4. Reference map (Empo, branch main)
| Topic | Where |
|---|---|
| MV/MZ runtime: NW.js shim, fs over XHR, frames, pause, speed, keys | `mvmz-apple-mobile/src/runtime.js` |
| MV/MZ web view setup, user agent, delegates | `mvmz-apple-mobile/src/mvmz_core.m` |
| File server: PUT/DELETE/MKCOL/MOVE/HEAD, case-insensitive, ranges | `mvmz-apple-mobile/src/MvmzFileServer.m` |
| Placing the game view, safe area, portrait position, snapshot on pause | `cores/mvmz/mvmz_app_bridge.m` |
| Controls model, layout, grid snap, per-orientation profiles | `ios/Empo/src/Player/ControlsLayout.swift`, `ControlsLayout+GridSnap.swift`, `ControlsZoneGeometry.swift`, `LayoutProfilesManager.swift`, `LayoutProfileViews.swift`, `UserControlsFile.swift` |
| Control editing, touch capture | `ControlsEditModifier.swift`, `ControlTouchCapture.swift`, `GameControls.swift`, `PlayerControlsOverlay.swift` |
| Physical controllers and bindings | `GameControllerReader.swift`, `ControllerInputManager.swift`, `BindingStore.swift`, `BindingsCatalog.swift`, `BindingsView.swift`, `KeyboardInputManager.swift` |
| Toolbar, more sheet, runtime state, debug overlay | `PlayerToolbar.swift`, `PlayerMoreSheet.swift`, `PlayerRuntimeState.swift`, `DebugOverlayView.swift`, `PlayerView.swift` |
| Library, import, backup, hints | `ios/Empo/src/Library`, `ios/Empo/src/Backup`, `ios/Empo/src/Hints`; `docs/import-pipeline.md` |
| Settings | `ios/Empo/src/Settings/SettingsView.swift`, `SettingsComponents.swift`, `LicensesView.swift` |
| Design system | `ios/Empo/src/Design`, `docs/design-system.md` |
| mkxp-z core pattern | `cores/mkxp`, `cores/cores.sh`, `cores/framework-common.sh`, `cores/GameCore.h`, `cores/gamecore.exports`, `ios/Empo/docs/cores.md`, `ios/Empo/src/Cores`, `ios/Empo/project.yml` |
| Archive import (7z/rar/exe/jgp) | search Empo for `7z`, `rar`, `jgp`, `Archive` in `ios/Empo/src/Library` and `ios/Empo/vendor` |

## 5. Writing Swift that compiles first time
Nothing is compiled before you push. Treat every file as if a single error fails the whole build.
- Before pushing each part, re-read every changed or new file top to bottom and check: imports (`UIKit`, `SwiftUI`, `WebKit`, `GameController`, `LocalAuthentication`, `Combine`, `ZIPFoundation`, `AVFoundation`, `Photos`); labels of every call; `self.` in escaping closures inside classes; `@MainActor` on UI and WKWebView code and `Task { @MainActor in }` where needed; optional unwrapping; `let` vs `var`; exhaustive `switch`; every type you use exists (grep the repo); no duplicate type names; protocol conformances complete; Codable keys.
- Use only APIs that exist on iOS 16. Newer APIs (`WKWebsiteDataStore(forIdentifier:)` iOS 17, `Translation` iOS 17.4/18, `UIImage` symbol effects) go behind `#available` with a fallback.
- Prefer simple UIKit/SwiftUI code over cleverness. No new packages except what archive import needs (check licenses). No Objective-C bridging header unless Part G needs it.
- Settings keys go in `SettingsKey` (Models.swift) and defaults in `NexPlayApp.init` registration.
- New `Game` fields are optional or defaulted. Change games only via `store.mutate(id)`.
- New files are picked up automatically: `project.yml` has `sources: - path: NexPlay`.
- Info.plist: read the file, add keys, keep it valid XML (`NSFaceIDUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` if the Files-app folder is built, `UIBackgroundModes` not needed).
- Never put an untested regex-heavy or reflection-heavy trick in the Swift side. Put logic in JS strings you can read once more.
- After each push you cannot see CI. So do a second review pass on the riskiest file of the part before moving on.

## 6. Parts

### Part A (1.1.3): Base check
- Read every Swift file, `Info.plist`, `tools/make_icon.py`, `project.yml`, and `docs/`. Fix real bugs you see (not style).
- Check that `LibraryStore` deletes a game's folder and data store, imports ZIP/folder/HTML, and that `GameDetailView` and `LibraryView` compile against the current `Game`.
- Add a Debug/Diagnostics row to Settings later in D; nothing else here. Push if you changed anything; otherwise skip the push and start version numbering at B.

### Part B (1.2.0): NW.js shim and file-based saves
Scope:
- `NexSchemeHandler`: add PUT, DELETE, MKCOL, MOVE, HEAD, and directory listing (GET on a directory returns a JSON array of names when the URL is requested with header `X-Nex-List: 1`, otherwise it serves `index.html` as now). Headers on HEAD/GET: `X-Nex-Kind` (`file`/`directory`), `X-Nex-Mtime` (ms). Game root itself is read-only. All writes inside the game folder only, atomic (`.atomic`), create intermediate directories. Request bodies arrive in `request.httpBody` (if nil, also check `httpBodyStream`).
- New script in `PageBridge.swift`: `PageScripts.nwShim` for RPG Maker games: `window.require` (`fs`, `path`, `os`, `nw.gui`), `window.nw`, `window.process` (`cwd()` returns `/`; `platform` `linux`; `mainModule`; `versions`; `env`; `argv`; `exit`; `on`), sync XHR fs (`existsSync`, `statSync`, `readFileSync` text and binary, `writeFileSync` text and `Uint8Array`/`ArrayBuffer`, `unlinkSync`, `mkdirSync`, `readdirSync`, `renameSync`, `rmdirSync`) plus callback versions, `nw.gui.Window.get()` Proxy of no-ops, `window.close` and `nw.App.quit` post an exit message handled by the app. Adapt from `runtime.js`; use the `X-Nex-*` header names. Binary `writeFileSync` must send a `Uint8Array` body (XHR send of typed arrays works).
- Setting `nwMode` (default true) in Settings > RPG Maker games; per-game override `Game.nwMode: Bool?` (nil = follow the setting) in the game detail sheet. Inject the shim only when on.
- Save migration (nwMode turning on for a game that has browser-mode saves): in `SaveTools`, JS that reads MV localStorage keys (`RPG Global`, `RPG File<N>`, `RPG Config`) and MZ IndexedDB records and writes them as files: MV: `save/global.rpgsave`, `save/file<N>.rpgsave`, `save/config.rpgsave` (content is the LZString-compressed string the engine already stored, so write it unchanged); MZ: `save/` files named `config.rmmzsave`, `global.rmmzsave`, `file<N>.rmmzsave` with the stored strings. Run once per game (store `Game.savesMigrated: Bool?`), never delete the old data, write a log line per file. If MZ records are binary or an unknown format, skip them and log it.
- Save files live at `<game folder>/<www path>/save/` as the engine decides; just let the shim answer. Do not move them.
- Backup/restore for nwMode games: zip the `save/` folder of the game with ZIPFoundation to a temp file (`<Name>-saves-<date>.zip`) and share it; restore picks a zip, shows a confirmation naming the game, backs up the current `save/` to `Backups/<game>/before-restore-<date>.zip`, then extracts. Keep the JSON tool for browser-mode and HTML5 games. The player menu "Saves" picks the right tool for the game.
- Game detail sheet: show save count, size and last save date for nwMode games; buttons Export, Import, Delete Saves (confirmation naming the game).
Acceptance: save, force-quit, reopen: save still there. Export zip, delete saves, import: save returns. A plugin that calls `require('fs')` starts.

### Part C (1.3.0): Controls
- Model (`ControlsLayout.swift`): control kinds `dpad`, `confirm`, `cancel`, `menu`, `dash`, `pageUp`, `pageDown`, `fastForward`, `custom(keyCode)`; each has normalized center (x, y in 0...1 of the screen), size, opacity, visible. A layout is a list of controls. A `LayoutProfile` has a name and two layouts (portrait, landscape).
- Storage (`LayoutStore`): JSON in Application Support: `Layouts/default.json` and `Layouts/<game-uuid>.json`; a game with no file follows the default profile. Actions: save, reset, copy to default, copy default to game.
- Overlay (`GamepadOverlay.swift` replaced or extended): draw controls from the layout, multi-touch, D-pad 4/8 directions with a dead zone, release on touch end, `onKey` stays as the output. Opacity and size from the layout. Haptics (`UIImpactFeedbackGenerator`, setting `hapticsEnabled` default true, strength light/medium/heavy).
- Edit mode: game menu > Edit Controls. Drag to move, pinch or two-finger on a selected control to resize, slider for opacity, grid snap toggle, Reset, Done. Saves per orientation.
- Control bar: optional bar (setting `controlBar`, default off) with fast-forward toggle, menu, restart, screenshot.
- Physical controllers: `PhysicalControllerManager` using `GCController` (`extendedGamepad` handlers) to send the same keys through `__nexKey`; default map A=OK, B=cancel, X=menu, Y=dash, L1/R1=page up/down, D-pad and left stick = arrows; a remap screen in Settings > Controls storing `[button: PadKey]` in UserDefaults as JSON. Do not call `navigator.getGamepads` overrides. Avoid double input: if the Gamepad API also feeds the game, only send keys for buttons the remap screen assigns, and set a setting `controllerMode` (`keys` default, `gamepadAPI`).
- Portrait position: setting per game `portraitAlignment` (top, center) pushes the web view to the top or center of the safe area in portrait; the free area below is where controls sit. Implement by changing the web view constraints (top-aligned with height from the 16:9-ish game aspect ratio reported by the page: add `window.webkit.messageHandlers.nexLog`-style `nexSize` message with `Graphics.width/height` from the runtime; fall back to full height until known).
- Screenshot: `webView.takeSnapshot` then save to Photos (`PHPhotoLibrary`, `NSPhotoLibraryAddUsageDescription`).
Acceptance: move and resize the D-pad in portrait and landscape, quit and reopen: layout stays. Haptic on press. A controller moves the hero and opens the menu. Portrait top alignment leaves room for the controls.

### Part D (1.4.0): Library, privacy, backups, settings
- Library: grid and list layouts (setting `libraryLayout`), sort (recent, name, added, play time), search, collections: `Collection { id, name, gameIDs, isHidden }` stored in `Collections.json`; create, rename, delete, add/remove games (context menu and detail sheet), collection chips at the top, bulk select and delete with confirmation, empty state with import hint.
- Privacy: `PrivacyLock` using `LocalAuthentication` (`.deviceOwnerAuthentication`, so passcode fallback works). Games and collections have `isHidden`; hidden items are not shown until unlocked via a lock button in the library; unlock lasts until the app backgrounds. `NSFaceIDUsageDescription` in Info.plist. `Game.isHidden: Bool?`.
- Auto backups: `AutoBackup` zips each nwMode game's `save/` folder into `Backups/<game-uuid>/<yyyy-MM-dd-HHmmss>.zip` when a session ends (shutdown) and on app background, if saves changed (compare newest file mtime). Keep the last N (setting `autoBackupCount`, default 5). Detail sheet lists backups, restore with confirmation. Setting to expose the Backups folder in the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, and place a `NexPlay Backups` folder in Documents; skip if it complicates; document the decision).
- Settings screen rebuilt (SwiftUI): search field at top filters rows; grouped cards with coloured icon tiles; groups Appearance (accent colour, library layout, library background plain/gradient/image, app icon), Controls (haptics, control bar, controller mode, remap), Gameplay & Performance (orientation default, desktop mode, sharp pixels, NW.js mode, keep awake, silent-mode audio, portrait alignment default), Privacy (lock settings), Import & Backup (auto backup count, media conversion, backups location), Translation (in F), About (version, credits, Show Tips Again, Diagnostics: shows the app-wide log and a share button), Reset to Defaults (confirmation, keeps games). Dark space-style background optional but not required: keep it simple and readable (dark gradient is enough).
- Alternate app icons: add 2 or 3 alternates generated by an extended `tools/make_icon.py` (accept a style argument) listed under `CFBundleIcons` in Info.plist with `CFBundleAlternateIcons`; if the CI icon generation cannot be extended safely, ship only the default icon and note it.
- Tips: first-run hints (import, menu button, edit controls), `Show Tips Again` resets `tipsSeen`.
Acceptance: collection hidden behind Face ID; a backup appears after a session; Reset to Defaults restores settings.

### Part E (1.5.0): Import and media
- Import `.7z`, `.rar` and self-extracting `.exe`: find what Empo uses (search its repo and `vendor/`), pick a library that builds in CI without a Mac (a Swift package or vendored C source via XcodeGen), check its license, add it to `project.yml` packages or sources. If nothing is safe and buildable, keep the clear error message, and say so in your final message. Do not guess a package URL: verify with `get_file_contents` or web search.
- Import progress UI (SwiftUI sheet, cancel, summary: engine, size, warnings), run in `Task`, never block the main thread.
- Warnings: no `index.html`, encrypted assets (`.rpgmvp`, `.rpgmvo`, `.rpgmvm` are fine: MV decrypts in JS), games needing Windows-only features (`.exe`-only with no `www`), nested games.
- Media conversion setting (`convertMedia`, default off): for MV/MZ games, when `Utils.canPlayOgg` is false on this device, convert `.ogg` to `.m4a` with `AVAssetExportSession` only if AVFoundation can read the source; skip files it cannot read and log them. Never modify originals. If OGG plays on the owner's device (unknown), leave this off by default.
- Detect XP/VX/Ace folders (`Game.ini`, `Data/Scripts.rxdata`, `.rvdata`, `.rvdata2`, `RGSS*.dll`) and add `GameEngine` cases `rpgXP`, `rpgVX`, `rpgVXAce`, `isRPGMaker` stays true only for MV/MZ (add `isRuby` property). Keep all `switch`es exhaustive (grep every `switch` on `GameEngine`). Library shows an engine badge and a "needs mkxp core" notice until G is enabled.

### Part F (1.6.0): Translation
- Setting `translationEnabled` (default off), `translationTarget` (language code, default `en`), per-game override. RPG Maker MV/MZ only.
- JS hook (`PageScripts.translate`): wrap `Window_Base.prototype.drawTextEx` input (and `Window_Message` text via `Game_Message.add` / `convertEscapeCharacters`) so that every new string is posted to the app (`nexTranslate` message handler) and replaced with a cached translation when available; untranslated text shows as is; after translation arrives, ask the window to refresh. Strings with escape codes: translate only the text segments between codes.
- Swift: `Translator` actor with a per-game JSON cache `Translations/<game-uuid>.json`. Engine: Apple `Translation` framework when `#available(iOS 18.0, *)` (`TranslationSession` needs a SwiftUI host: host a hidden SwiftUI view with `.translationTask`). On earlier iOS, show that translation needs iOS 18 and keep the setting disabled. Do not send text to any online service.
- Settings > Translation: enable, target language, clear cache.
Acceptance on iOS 18: dialogue appears translated after a short delay, cache is reused next run. On older iOS the setting explains itself and does nothing.

### Part G (1.9.0): RPG Maker XP/VX/Ace (mkxp-z), behind a flag
The core is large and cannot be tested here, so isolate it so main always builds:
- Add a compilation flag `NEXPLAY_MKXP` (project.yml `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `GCC_PREPROCESSOR_DEFINITIONS`), OFF by default. All core code lives in `NexPlay/MKXP/` wrapped in `#if NEXPLAY_MKXP`; the rest of the app only talks to a small protocol `RubyGameRunner` with a stub implementation that shows "This build has no mkxp core" when the flag is off.
- Read Empo's `cores/mkxp/*`, `cores/cores.sh`, `cores/framework-common.sh`, `cores/GameCore.h`, `cores/gamecore.exports`, `ios/Empo/docs/cores.md`, `multi-ruby.md`, `multi-session.md`, and its Swift bridging in `ios/Empo/src/Cores`. Copy the pattern: pinned release version + SHA-256 in a `.version` file, a fetch script that downloads the prebuilt core tarball in CI (`tools/fetch_mkxp_core.sh`), header include path and static library linked into the app, a small Objective-C/C bridge calling `gamecore_*` functions to start a game, inject keys, pause/resume, and show the SDL/Metal view in a `UIViewController`.
- Write `docs/workflow-2.0.0.yml`: the existing build workflow plus a step that runs the fetch script before `xcodegen generate` and passes the flag to xcodebuild. Tell the owner to paste it as `.github/workflows/build.yml` ONLY after the flag-off build passes, and tell them how to turn the flag on.
- Player: for `isRuby` games open the mkxp view controller with the same menu (restart is not supported: explain "close the app and reopen to start another Ruby game", like Empo), reuse the controls overlay and controller manager from Part C to feed `gamecore_injectKeyEvent`.
- Credits: mkxp-z (GPLv2+), Empo cores (GPLv3), Ruby, SDL, ANGLE as Empo's `licenses.json` says.
Acceptance (after the owner turns the flag on): an XP or Ace game starts, takes input, plays sound, saves. If the core cannot be linked reliably from CI, leave the flag off and say exactly what is missing.

### Part H (2.0.0): Finish
- Version 2.0.0 build 12. Update CLAUDE.md (layout, rules, roadmap, what is flag-gated), tick this file, update `docs/PROMPT.md` if needed, update Settings > Credits with every source used.
- Final self-review of all new files for section 5 errors; fix what you find and push.
- Final message as described in section 2.

## 7. Cross-cutting requirements
- Never lose a save: atomic writes, back up before migrating or restoring, confirm before deleting and name the game.
- NexPlay itself uses no network. Games may use it unless `blockNetwork` is on.
- Data lives in Application Support/NexPlay (Games, Layouts, Backups, Translations, Collections.json). Deleting a game removes its folder, data store, layout and backups only after confirmation.
- Nothing heavy on the main thread: import, backup, zip, scan run in `Task` with progress.
- Dynamic Type in SwiftUI screens; accessibility labels on icon buttons.
- Use `GameLog` for anything the owner may need to paste when a game fails; add an app-wide log for non-game problems (Diagnostics).

## 8. Device test checklist (the owner runs this after the build)
1. App launches, library shows, an MV game and an MZ game start.
2. Sound plays (also with the silent switch on).
3. Touch controls work; edit mode moves and resizes; layout survives a restart. A controller works if available.
4. Save, quit the app completely, reopen, load: the save is there. Export saves, delete, import: back.
5. Rotate, fast-forward x2/x4, leave and return: no freeze, no sound burst.
6. Create a collection, hide it, relaunch: asks for Face ID.
7. A backup zip appears after a session; restore works.
8. Import a `.7z` or `.rar` (if Part E shipped it).
9. Translation on iOS 18 (if available).
10. Game Log shows no repeating errors. If something fails, share the log from the game menu and paste the Actions red lines if the build failed.

## 9. Open questions (decide by sensible default, note in CLAUDE.md)
- Does OGG play on the owner's phone without conversion? Default: conversion off.
- Does desktop mode break touch in any game? Default: on, with the setting to turn it off.
- iCloud sync of saves: not built (a self-signed IPA probably cannot use iCloud entitlements). Files-app folder instead.
