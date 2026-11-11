# NexPlay

Personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+), with RPG Maker XP/VX/Ace through the mkxp-z core in builds that turn on `NEXPLAY_MKXP`.
Not a general web browser: everything in here is treated as a game. Version 2.1.0 (build 15).

**Read `docs/SPEC.md` for the plan, `docs/RESEARCH.md` for what the reference apps do. Paste-ready prompt for new chats: `docs/PROMPT.md`.**

## How the owner works
- iPhone only, no Mac or PC. GitHub Actions builds an unsigned IPA; the owner signs it with their own certificate.
- Swift can't be compiled in the Claude environment. If the Actions build fails, the owner pastes the red error lines; fix the first error first.
- Push source changes straight to `main`.
- `.github/workflows/*` can't be pushed from Claude. Give the owner the full file to paste on github.com. The 2.0.0 workflow is `docs/workflow-2.0.0.yml`.
- **Bump the version on every push**, without being asked: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Patch for fixes, minor for features, major for big changes.
- The old NexHTML repo is left untouched.
- Keep replies short: what changed and what the owner must do, if anything.
- The owner compares with RPGPlayer screenshots (ideas only) and Empo (code may be copied).

## Standing permission
The owner allows you to look up and copy code from Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile, mkxp-z, EasyRPG and other open-source projects **without asking**. Rules: check the LICENSE first; keep the attribution in the file header and in Settings > Credits; never name the app Empo or use its icon; never copy from closed apps (RPGPlayer, ArkRPG...: ideas only).

## Layout
- `project.yml`: XcodeGen config (the Xcode project is generated in CI, never committed). Links the system libarchive (`-larchive`) and uses `NexPlay/NexPlay-Bridging-Header.h`.
- `tools/make_icon.py`: draws the app icon during the build.
- `tools/fetch_mkxp_core.sh`, `tools/mkxp/core.version`: CI-only build of MkxpCore.framework (downloads the pinned mkxp-z-apple-mobile release and Empo's framework scripts at a pinned commit into `vendor/empo`, never committed).
- `docs/`: SPEC, RESEARCH, PROMPT, `workflow-2.0.0.yml`.
- `NexPlay/`: all Swift sources.
  - `Models.swift`: `Game`, `GameEngine` (MV, MZ, HTML5, XP, VX, VX Ace; `isRPGMaker` = MV/MZ, `isRuby` = XP/VX/Ace), `OrientationMode`, `SettingsKey`.
  - `LibraryModels.swift`: more settings keys (`SettingsKey.all` for Reset), `LibrarySortOrder` (10 sorts), `GameCollection` + `CollectionStore` (`Collections.json`), `PrivacyLock` (hidden games in UserDefaults, Face ID/passcode), `AutoBackup`, `AppState`.
  - `FileUtils.swift`: `Paths` (Games, Backups, Rescued Saves, save folder), MIME, `GameScanner` (MV/MZ/HTML5 detection, titles, sizes).
  - `ImportPipeline.swift`: staged import (zip-slip check by path components, cancel, out-of-space, ZIP name encoding repair, Ruby detection, warnings), folder copy through NSFileCoordinator (downloads iCloud placeholders), atomic install, update in place, staging sweep at launch.
  - `ArchiveExtractor.swift` + `NexPlay-Bridging-Header.h`: 7z, RAR, TAR, gz/xz/bz2, CAB, ISO and SFX .exe through the libarchive that ships with iOS (declarations in the bridging header because the iOS SDK has no libarchive headers). ZIP stays with ZIPFoundation and falls back to libarchive.
  - `LibraryStore.swift`: library persistence, import flow (progress, cancel, update-or-add), delete with save rescue. Change games only via `store.mutate(id) { ... }`.
  - `NexSchemeHandler.swift`: serves `nexplay://<game-uuid>/...` (own origin per game, ranges, case-insensitive, symlink-safe) plus HEAD/PUT/DELETE/MKCOL/MOVE and `X-Nex-List: 1` listings for the NW.js shim; game and entry folders protected; `fileOverride` (plugins.js, translation dictionary).
  - `PageBridge.swift`: injected scripts (diagnostics, `window.nexplay`, key bridge, FPS, RPG Maker runtime with speed/pause/size, NW.js shim).
  - `SaveTools.swift`: data stores; browser-mode save backup/restore/clear; one-time migration of browser saves into files.
  - `SaveArchive.swift`: file saves: info, ZIP export/restore, backups (`Backups/<game-uuid>/`), `.nex-displaced.bak`, rescue (`Rescued Saves/<name>-<uuid>/`).
  - `ControlsLayout.swift`: `PadKey`, `ControlAction`, `ControlItem`, `LayoutProfile`, `LayoutStore` (`Layouts/default.json`, `Layouts/<uuid>.json`).
  - `ControlBar.swift`: player setting keys (`SettingsKey.playerKeys`), `ControlPrefs` (read at game start; `display`/`stored` apply and undo the global pad size, opacity and D-pad/joystick type), `ControlBarView` (draggable handle that opens into the bar), `KeySenderField` (hidden text field: typing becomes key presses).
  - `GamepadOverlay.swift`: on-screen controls and their edit mode. `PhysicalControllers.swift`: GCController input, button maps, remap screen.
  - `PlayerFeatures.swift`: `PlayerFeature` plug-ins, registry, file overrides, `KeyRouter`. **Add new player features here, not in PlayerViewController.**
  - `GameTools.swift`: plugin manager (`PluginOverrides/<uuid>.json`) and cheats. `Translation.swift`: MTool dictionary translation (`Translations/<uuid>/`).
  - `PlayerViewController.swift`: the web game screen: control bar, error banner, portrait offset, controller connect/disconnect, game menu. `GameScreen.swift`: picks the web player or the Ruby runner; `RubyGameRunner` protocol and `RubyCoreStub`.
  - `MKXP/MkxpRunner.swift`: Ruby core runner (dlopen of `Frameworks/MkxpCore.framework`), compiled only with `NEXPLAY_MKXP`.
  - `GameLog.swift`, `AppLog.swift`: game log and app log (Caches/NexPlay-app.log, crash note at launch).
  - `Background.swift`: `AppBackground` (animated Canvas themes: Cosmic Nebula, Frost, Ember, Aurora, Plain; plain system colour in light mode).
  - `SettingsView.swift`: settings home (page tiles, About, Reset, search over `NexSettingsPage.rows`) and the pages: Appearance, Controls, Gameplay & Performance, Translation, Privacy, Import & Backup, Advanced; Credits, App Log.
  - `LibraryView.swift`, `GameDetailView.swift`, `ImportPicker.swift`: screens.

## Rules
- Codable fields added to `Game` must be optional or have a default, so old libraries still load. An unreadable `library.json` is copied aside before anything overwrites it.
- Keep every `switch` on `GameEngine` exhaustive (Models, ImportPipeline warnings).
- Compare resolved paths when computing relative paths (iOS reports `/var` as `/private/var`).
- Never lose a save: atomic writes; back up before restoring, deleting saves or migrating; replaced files become `.nex-displaced.bak`; deleting a game rescues its save files first.
- Do not override `navigator.getGamepads`: physical controllers reach the game through the Gamepad API too (Empo disables it; NexPlay does not).
- **The NW.js shim's `process.versions` must not contain `node`**: Emscripten code (MZ's Effekseer, some plugins) then thinks it is in Node.js, reads `__dirname` and the game stays black. Empo leaves `versions` empty.
- New settings keys go in the `SettingsKey` extension of the file that uses them, get a default in `NexPlayApp.defaultSettings`, and join a key list Reset clears (`all`, `playerKeys`, `backgroundKeys`).
- Message handlers: `nexStats`, `nexLog`, `nexExit`, `nexSize` (sent, not handled yet), feature handlers (`nexTranslate`). Remove each in `shutdown()`.
- Write boring, explicit Swift for iOS 16 (nothing is compiled before pushing). Re-read changed files for imports, labels, `self.` and `@MainActor` mistakes.
- Use `GameLog` for game problems and `AppLog` for app problems.

## Decisions
- NW.js mode is on by default for MV/MZ; per-game override in Info & Settings. Save migration runs once per game, copies only, never overwrites an existing save file, reloads when it wrote anything.
- Browser-mode data (localStorage/IndexedDB) can't be rescued when a game is deleted; the dialogs say so.
- Backups are in `Backups/<game-uuid>/`; retention keeps the last 5/10/20 automatic ones, `before-*` safety copies are kept.
- "Show in Files" not added: data lives in Application Support; moving it to Documents would move every game. Use ZIP export.
- Controller defaults: A OK, B cancel, X menu, Y dash, L1/R1 page up/down, R2 fast forward, Menu = menu. "keys" mode also leaves the Gamepad API alone.
- Fast-forward button toggles 1× and `Game.fastForwardSpeed` (2-9, default 2); menu offers 1/2/3/4/6/9×.
- Hidden games are a UUID list in UserDefaults (`hiddenGames`), not `Game.isHidden`. Collections can be hidden too.
- Cheats are always in the game menu for MV/MZ; only numbers are passed to JS.
- An import whose title and engine match an installed game asks: Update It / Add as New / Cancel.
- ZIP names that are not UTF-8: Shift-JIS when kana appear, else GBK, else Big5/EUC-KR, else CP437. libarchive names use `archive_entry_pathname_utf8` first.
- Translation: on/off is read when a game starts; turning it on mid-game needs leaving and reopening the game.
- OGG conversion is not built (Empo treats OGG failure as simulator-only).
- XP/VX/Ace: the core is loaded with dlopen from `NexPlay.app/Frameworks/MkxpCore.framework`, one Ruby game per app launch, touch controls in a separate window over the core, keys sent as SDL scancodes. The core release is built by Empo for iOS 26; whether it runs on older iOS is unknown (`MKXP_MIN_OS` env can change the target).
- Control bar (2.1.0) replaces the old menu button: handle position is saved normalized (`barPosition`); the X asks before exiting; the gear opens the full game menu; auto-hide after 5 s, a tap on the game (not on a control) wakes it; hidden while a controller is connected unless "Show Control Bar With Controller". Typed keys go down and up 80 ms apart so RPG Maker sees them.
- Global pad size/opacity/type are applied when a layout is shown and undone before it is saved, so saved layouts stay at 1×.
- Orientation: "Auto-rotate In Games" forces auto for every game; "Game Orientation" is the lock for new RPG Maker games (button applies it to all); outside games the app is portrait unless "Auto-rotate Outside Games".
- Portrait game position moves the whole web view up (constraint constant), so touches stay correct.
- The player shows a red banner for script errors in the first 30 s and when the start page comes back as plain text (file server error); 15 s after load the game log records the current RPG Maker scene. Use these when the owner reports a black screen.

## Not built (reasons: time, can't test without a device, or needs entitlements)
- B: per-file recovery list for displaced copies; Show in Files.
- C: soft keyboard for non-letter keys, screen scaling Fit/Fill/Stretch, fill colour, device skin; P2 pause snapshot, game `controls.json`/JoiPlay `gamepad.json`, game screen drag/resize.
- D: drag-to-reorder games; accent colour, library background image, alternate app icons, cover picker, version edit, "Changed by you" markers, storage manager, invalidate missing games, gamepad navigation of the library, What's New/Tips, WebDAV, iCloud sync (needs an iCloud entitlement the owner's certificate likely lacks), localization, widgets, landscape console menu.
- E: multi-part RAR/7z (part1, part2), password-protected archives, CAB-based RPG Maker installers (Empo uses libmspack); multi-root picker; media conversion; `.jgp` metadata, EXE icons, Enigma.
- F: Apple on-device translation (iOS 18 Translation framework); translation button on the control bar; global mods.
- G: per-game Ruby-core settings (upscaler, font hinting, VSync, compatibility estimate), MIDI SoundFont import, pause/resume and quit from inside a Ruby game, game rect/viewport handling. The mkxp build path is untested.

## Roadmap
- 1.1.4 base check, AppLog. 1.2.0 NW.js saves. 1.3.0 controls. 1.4.0 library/backups/settings/plugins/cheats. 1.5.0 import pipeline. 1.6.0 translation. 1.9.0 mkxp scaffolding. 2.0.0 finish. 2.1.0 control bar, settings pages, 7z/RAR, black-screen fix.
- Next: device test of 2.1.0 (black screen gone? banner text if not), then the first mkxp build (Actions > Run workflow > mkxp) and fixes from its log.
- 3.0: RPG Maker 2000/2003 (EasyRPG), back burner.
