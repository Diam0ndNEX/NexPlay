# NexPlay spec

The full plan for the AI that builds NexPlay. Read CLAUDE.md first, then this file. Work through the milestones in order.

## 1. Product
NexPlay is a personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+), later also RPG Maker XP/VX/Ace. It is not a web browser: everything in it is a game. One user (the owner), sideloaded, never on the App Store.

Goals, in order: games run correctly, saves never get lost, controls feel good on a phone, the library is pleasant.
Non-goals: general browsing, ads, accounts, analytics, App Store compliance, Mac/iPad polish (iPad should work but is not tested).

## 2. Working rules
- The owner has only an iPhone. GitHub Actions builds an unsigned IPA. Claude cannot compile Swift. Every error comes back as pasted red lines from Actions: fix the first error first, push, repeat.
- Because nothing is compiled before pushing, write boring, explicit Swift. Prefer APIs available on iOS 16. Gate newer APIs with `#available`. No clever generics, no new package dependencies without a strong reason (ZIPFoundation is the only one). Re-read every file you changed for missing imports, wrong labels, missing `self.`, and actor isolation (`@MainActor`) mistakes before pushing.
- Push one milestone per commit, straight to `main`. Never push a milestone that rewrites more than about 6 files at once unless it is a pure addition. If a milestone is bigger, split it (1.2a, 1.2b).
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` on every push, without being asked. Patch for fixes, minor for features.
- Workflow files (`.github/workflows/*`) cannot be pushed by Claude. Give the owner the full file to paste on github.com.
- Keep replies to the owner short: what changed, what to do (if anything). The owner tests on a real device and reports back in plain words or pastes the Game Log.
- New Codable fields on `Game` must be optional or have defaults. Change games only through `store.mutate(id)`.
- Update CLAUDE.md (layout, rules) and this file's checkboxes in the same commit as the code.

## 3. Standing permission: look things up and copy
The owner has said: check Empo and other sources and copy from them without asking. So:
- Do it freely. Read the source, copy or adapt what fits, and push. No need to ask first.
- Sources to use: Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile (all by mateo-m), mkxp-z, EasyRPG, JoiPlay, and any other open-source project whose license allows it. Use search_code and get_file_contents on GitHub, and web search.
- License rules (these still apply):
  - Empo and its cores are GPL-3.0-only with additional terms. Copying into this private app is allowed. Keep the SPDX/copyright header or a short attribution comment in every file with copied or closely adapted code. Keep the Settings > Credits text up to date with every source used.
  - Never name the app "Empo", never use its icon or logo, never claim authorship of its code.
  - Before copying from any other repo, check its LICENSE. GPL, MIT, BSD, Apache are fine with attribution. No license, or a non-commercial/closed license: do not copy code, only learn the idea.
  - RPGPlayer is closed. Only the owner's screenshots exist. Copy ideas and settings layout, never assets, names or text.
- When Empo has a doc for the topic (`ios/Empo/docs/*.md`), read it before designing: `import-pipeline.md`, `pause-resume.md`, `design-system.md`, `cores.md`, `multi-ruby.md`, `multi-session.md`.
- If Empo's way conflicts with a NexPlay rule (for example it disables the Gamepad API, NexPlay uses it for controllers), keep the NexPlay rule and say so in CLAUDE.md.

## 4. Reference map (Empo, branch main)
| Topic | Where |
|---|---|
| MV/MZ runtime: NW.js shim, fs over XHR, frames, pause, speed, keys | `mvmz-apple-mobile/src/runtime.js` |
| MV/MZ web view setup, user agent, delegates | `mvmz-apple-mobile/src/mvmz_core.m` |
| File server: PUT/DELETE/MKCOL/MOVE/HEAD, case-insensitive, ranges | `mvmz-apple-mobile/src/MvmzFileServer.m` |
| Placing the game view, safe area, portrait position, snapshot on pause | `cores/mvmz/mvmz_app_bridge.m` |
| On-screen controls model, layout, snapping, per-orientation profiles | `ios/Empo/src/Player/ControlsLayout.swift`, `ControlsLayout+GridSnap.swift`, `ControlsZoneGeometry.swift`, `LayoutProfilesManager.swift`, `LayoutProfileViews.swift` |
| Control editing (drag, resize) | `ControlsEditModifier.swift`, `ControlTouchCapture.swift`, `GameControls.swift`, `PlayerControlsOverlay.swift` |
| Physical controllers and key bindings | `GameControllerReader.swift`, `ControllerInputManager.swift`, `BindingStore.swift`, `BindingsCatalog.swift`, `BindingsView.swift` |
| Player toolbar, more sheet, runtime state, debug overlay | `PlayerToolbar.swift`, `PlayerMoreSheet.swift`, `PlayerRuntimeState.swift`, `DebugOverlayView.swift` |
| Library, import, backup, hints | `ios/Empo/src/Library`, `Backup`, `Hints`; `docs/import-pipeline.md` |
| Settings screens | `ios/Empo/src/Settings/SettingsView.swift`, `SettingsComponents.swift`, `LicensesView.swift` |
| mkxp-z core pattern | `cores/mkxp`, `cores/cores.sh`, `cores/GameCore.h`, `ios/Empo/docs/cores.md` |

## 5. RPGPlayer reference (from screenshots)
Settings screen, top to bottom: search box, profile card, Support (Support Development, Discord), then groups:
- Appearance: theme, background, library layout, language, app icon.
- Controls: virtual gamepad, control bar, haptics, physical controllers.
- Gameplay & Performance: orientation, VSync, portrait position, native engine visuals.
- Translation & Engines: in-game text translation.
- Privacy: hide games and collections behind Face ID, Touch ID or a passcode.
- Import & Backup: media conversion, iCloud sync, automatic save backups.
- About: app name and version, platform, Show Tips Again. Reset to Defaults at the bottom.
Look: dark, space-themed background, large rounded cards, coloured icon tiles, pixel-style font for titles, a floating close button.
NexPlay does not need Support, Discord or a profile card.

## 6. Milestones
Each milestone lists scope, what to copy from, and acceptance criteria the owner can check on a phone. Mark `[x]` when pushed and confirmed working.

### [x] 1.1.0 Runtime hardening
File server (case-insensitive, symlink-safe, background), RPG Maker runtime (speed, pause, focus), desktop mode, sharp pixels, game log, prompt() dialogs, credits.

### [ ] 1.1.x Fixes from the first device tests
Whatever the owner reports from a real MV game and a real MZ game: black screen, no sound, wrong size, input problems. Read the Game Log text the owner pastes. Likely suspects: audio (OGG on device), MZ height with desktop mode on and off, saves persisting across restarts, overlay controls vs touch.

### [ ] 1.2 NW.js shim and file-based saves
Scope:
- Extend `NexSchemeHandler` with PUT, DELETE, MKCOL, MOVE, HEAD and directory listing (JSON array of names, headers `X-Nex-Kind` and `X-Nex-Mtime`). The game root itself is read-only. Writes stay inside the game folder.
- New injected script `NexNode.js` (RPG Maker only): `window.require` for `fs`, `path`, `os`, `nw.gui`; `window.nw`; `window.process` with `cwd()` returning `/` (MZ stops if it starts with `/private/var`), `platform: "linux"`, `mainModule`. Synchronous XHR for fs calls. Callback forms run one tick later. Window methods on `nw.gui` are no-ops via Proxy. `window.close` and `nw.App.quit` post an exit message.
- Result: `Utils.isNwjs()` is true, so MV/MZ keep saves as files (`save/file1.rpgsave`, MV `.rmmzsave` for MZ) inside the game folder instead of localStorage or IndexedDB.
- Migration: on first launch of a game with existing localStorage/IndexedDB saves and no `save/` folder, copy them out into files once (MV: `RPG Save` keys; MZ: `rpgsave` IndexedDB store), then keep both. Never delete the old data automatically.
- Setting `NW.js mode` (default on) in Settings > RPG Maker games, per-game override in the game detail sheet. Turning it off returns to browser mode and the old backup tool.
- Backup/restore: new file-based version zips the `save/` folder (ZIPFoundation) and restores from a zip. Keep the JSON tool for browser mode and HTML5 games.
- Game detail sheet: show save size and last save date, buttons Export Saves, Import Saves, Delete Saves (with confirmation).
Copy from: `runtime.js` (path, fs, nw), `MvmzFileServer.m` (answer method).
Acceptance: save in game, force-quit app, reopen: save still there. Export zip, delete saves, import zip: save back. A plugin game that calls `require('fs')` starts.

### [ ] 1.3 Controls
Scope:
- Controls model: a list of controls (D-pad, A/B/X/Y style buttons, menu key, shift/dash, page up/down, fast-forward toggle), each with position, size, opacity, and key binding.
- Edit mode from the game menu: drag to move, pinch or slider to resize, snap to a grid, reset button. Layouts saved per game and per orientation, with a default profile and the option to copy it to another game.
- Haptics: light tap on press, setting on/off and strength (`UIImpactFeedbackGenerator`).
- Control bar: optional thin bar with fast-forward, menu, restart, screenshot.
- Physical controllers: remappable bindings screen (`GCController`), default MV/MZ mapping (A=OK, B=cancel, X=menu, Y=dash, shoulders=page up/down). Keep the Gamepad API path working.
- Portrait position: where the game sits in portrait (top, center, bottom-ish), and the controls fill the free area under it.
- Screenshot button (save to Photos needs `NSPhotoLibraryAddUsageDescription` in Info.plist).
Copy from: `ControlsLayout*.swift`, `ControlsEditModifier.swift`, `LayoutProfilesManager.swift`, `BindingsCatalog.swift`, `GameControllerReader.swift`, `mvmz_app_bridge.m` (placeWebView).
Acceptance: move and resize the D-pad in portrait and landscape, quit and reopen, layout stays. Haptic on each press. A controller moves the hero and opens the menu.

### [ ] 1.4 Library and privacy
Scope:
- Library: grid and list layouts, collections (create, rename, add/remove games, show collection chips), bulk select and delete, sort (recent, name, added, play time), search, empty state with import hint.
- Privacy lock: games and collections can be hidden behind Face ID/Touch ID/passcode (`LocalAuthentication`, needs `NSFaceIDUsageDescription`). Hidden games vanish from the library until unlocked.
- Automatic save backups: after every session (and optionally every N minutes) copy `save/` to `Backups/<game>/<date>.zip`, keep the last N (setting). Restore from the game detail sheet. Optional copy into the Files app folder.
- Settings rebuilt as grouped cards like RPGPlayer: Appearance, Controls, Gameplay & Performance, Privacy, Import & Backup, About. Search box filters rows. Reset to Defaults with confirmation. Show Tips Again.
- Appearance: dark theme options, an accent colour, library background (plain, gradient, user image), alternate app icons (`UIApplication.setAlternateIconName`, icons drawn by `tools/make_icon.py`, listed in project.yml).
- Tips: first-run hints (import, menu button, controls editor), dismissible, re-showable.
Copy from: Empo `Library`, `Backup`, `Hints`, `Settings` folders, `SettingsComponents.swift`.
Acceptance: create a collection, hide it, relaunch: it asks for Face ID. A backup zip appears after a play session. Reset to Defaults restores settings and keeps games.

### [ ] 1.5 Import and media
Scope:
- Import `.7z`, `.rar` and self-extracting `.exe` if a pure-Swift or vendored C library can be built in CI without a Mac (check what Empo uses, copy it, keep its license). If it is not feasible, keep the clear error message and say why in CLAUDE.md.
- Import progress UI with cancel, and a result summary (engine, size, warnings).
- Media conversion at import (optional setting): OGG to M4A using AVFoundation only if iOS can decode the source; otherwise skip and rely on the web view. Never touch the original file; write `.m4a` next to it. MV falls back to `.m4a` when `canPlayOgg` is false.
- Detect and warn about encrypted assets, missing `index.html`, and games that need Windows-only features.
Acceptance: a `.7z` of an MV game imports and runs, or the app explains clearly why not.

### [ ] 1.6 Translation
Scope: optional in-game text translation for RPG Maker MV/MZ. Hook `Window_Base.prototype.drawTextEx` / `Bitmap.prototype.drawText`, collect strings, translate on device with Apple's `Translation` framework where available (iOS 17.4+/18) and cache results per game in a JSON file. Off by default. Settings: target language, engine, clear cache. Needs a design spike first: confirm what is available on the owner's iOS version before building.
Acceptance: Japanese game text shows in English for dialogue after one load, with the cache reused on the next run.

### [ ] 2.0 RPG Maker XP/VX/Ace via mkxp-z
Scope: follow Empo's core pattern. Read `cores/cores.sh`, `cores/mkxp/*`, `cores/GameCore.h`, `ios/Empo/docs/cores.md`, `multi-ruby.md`, `multi-session.md`, `import-pipeline.md`. Fetch prebuilt core releases (`mkxp-z-apple-mobile`) in the CI workflow instead of compiling them, verify the SHA-256 pin, link the static library, and add a bridge like `mvmz_app_bridge.m` for the SDL/Metal view. Detect `Game.ini`/`Data/*.rxdata|rvdata|rvdata2`. Known limits to accept: one Ruby game per app launch, Ogg/Theora movies only. This needs workflow and `project.yml` changes (the owner pastes workflow changes) and a bigger IPA; do it as 2.0a (build links core, shows version), 2.0b (starts a game), 2.0c (input, audio, saves).
License: mkxp-z is GPLv2+, Empo cores GPLv3. Credits screen must list them.
Acceptance: an XP or Ace game from the owner's library starts, takes input, plays sound, saves.

### [ ] 3.0 Back burner
RPG Maker 2000/2003 through EasyRPG. Only if the owner asks.

## 7. Cross-cutting requirements
- Never lose a save. Any code that writes or deletes save data must write atomically, and must back up first when migrating. Deleting needs a confirmation naming the game.
- No network use by NexPlay itself. Games may use the network unless `blockNetwork` is on.
- Storage: all data lives in Application Support/NexPlay. Deleting a game removes its folder, its data store and its backups only after confirmation.
- Performance: no work on the main thread that scans or reads big files. Import and backup run in `Task` with progress.
- Accessibility: Dynamic Type in SwiftUI screens, labels on icon buttons.
- Logging: use `GameLog` for anything the owner might need to paste when a game fails.

## 8. Device test checklist (the owner runs this after each milestone)
1. App launches, library shows, a game starts.
2. Sound plays (also with the silent switch on, if that setting is on).
3. Touch controls and, if available, a controller work.
4. Save, quit the app completely, reopen, load: save is there.
5. Rotate, fast-forward x2 and x4, leave the app and come back: no freeze, no sound burst.
6. Game Log shows no repeating errors. If something fails, share the log from the game menu.

## 9. Open questions to settle by testing
- Does OGG play on the owner's iPhone without conversion?
- Does desktop mode break touch input in any MV/MZ game?
- Which iOS version is the owner on (decides Translation and per-game data stores)?
- Does the owner want iCloud sync of saves? It needs a paid-account entitlement that a self-signed IPA may not get: ask before building, default to Files-app export instead.
