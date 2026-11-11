# NexPlay

Personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+).
Not a general web browser: everything in here is treated as a game.

**Read `docs/SPEC.md` for the full plan and milestones. Paste-ready prompt for new chats: `docs/PROMPT.md`.**

## How the owner works
- iPhone only, no Mac or PC. GitHub Actions builds an unsigned IPA; the owner signs it with their own certificate.
- Swift can't be compiled in the Claude environment. If the Actions build fails, the owner pastes the red error lines; fix the first error first.
- Push source changes straight to `main`.
- `.github/workflows/*` can't be pushed from Claude. Give the owner the full file to paste on github.com.
- **Bump the version on every push**, without being asked: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Patch for fixes, minor for features, major for big changes.
- The old NexHTML repo is left untouched.
- Keep replies short: what changed and what the owner must do, if anything.

## Standing permission
The owner allows you to look up and copy code from Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile, mkxp-z, EasyRPG and other open-source projects **without asking**. Rules: check the LICENSE first; keep the attribution in the file header and in Settings > Credits; never name the app Empo or use its icon; never copy from closed apps (RPGPlayer: ideas from screenshots only). Details and a map of useful Empo files are in `docs/SPEC.md` sections 3 and 4.

## Layout
- `project.yml`: XcodeGen config (the Xcode project is generated in CI, never committed).
- `tools/make_icon.py`: draws the app icon during the build.
- `docs/SPEC.md`, `docs/RESEARCH.md`, `docs/PROMPT.md`: plan, research digest and prompt.
- `NexPlay/`: all Swift sources.
  - `Models.swift`: `Game`, `GameEngine`, `OrientationMode`, settings keys.
  - `FileUtils.swift`: paths, MIME types, `GameScanner` (engine detection, titles, sizes).
  - `LibraryStore.swift`: library persistence and import (ZIP, folder, single HTML). Change games only via `store.mutate(id) { ... }`.
  - `NexSchemeHandler.swift`: serves each game at `nexplay://<game-uuid>/...` (own web origin per game, byte ranges, case-insensitive names, symlink-safe, reads on a background queue).
  - `SaveTools.swift`: per-game data stores, save backup/restore/clear through JS.
  - `PageBridge.swift`: injected scripts (diagnostics, key bridge, FPS, RPG Maker runtime with speed/pause).
  - `GameLog.swift`: in-app game log (console, errors, failed file loads) and its viewer. Use it to debug without a Mac.
  - `AppLog.swift`: app-wide log (imports, backups, crash notes) in memory + `Caches/NexPlay-app.log`; Settings > Advanced > App Log shares it. Also notes an unclean exit at launch (idea from Empo's CrashTracker).
  - `GamepadOverlay.swift`: on-screen D-pad and buttons.
  - `PlayerViewController.swift`: the game screen and its menu.
  - `LibraryView.swift`, `GameDetailView.swift`, `SettingsView.swift`: SwiftUI screens.

## Rules
- Codable fields added to `Game` later must be optional or have a default, so old libraries still load.
- Compare resolved paths when computing relative paths (iOS reports `/var` as `/private/var`).
- Engine detection: `js/rmmz_core.js` = MZ, `js/rpg_core.js` = MV, otherwise HTML5. The game root can be up to two folders deep.
- Never lose a save: atomic writes, back up before migrating, confirm before deleting.
- An unreadable `library.json` is copied aside (`library-unreadable-<time>.json`) before anything overwrites it.
- Do not override `navigator.getGamepads`: physical controllers reach the game through the Gamepad API here.
- Write boring, explicit Swift (nothing is compiled before pushing). Re-read changed files for imports, labels, `self.` and `@MainActor` mistakes.
- Use `GameLog` for game problems and `AppLog` for app problems.

## Roadmap (details in docs/SPEC.md)
- 1.1.0 done: hardened file server, RPG Maker runtime (speed, pause/resume, focus), desktop mode, sharp pixels, game log, prompt() dialogs, credits.
- 1.1.4 done: base check, AppLog, crash note, library.json safety.
- 1.2: NW.js shim and file-based saves (backup as zip).
- 1.3: Controls (editor, per-game layouts, haptics, controller bindings, portrait position).
- 1.4: Library (collections, Face ID lock, auto save backups, settings rebuilt like RPGPlayer).
- 1.5: Import 7z/RAR, media conversion. 1.6: Translation.
- 2.0: RPG Maker XP/VX/Ace through mkxp-z, following Empo's core pattern.
- 3.0: RPG Maker 2000/2003 (EasyRPG), back burner.

## Decisions
(Defaults chosen during the 2.0.0 run; change them if a device test says otherwise.)

## Not built
(Filled during the 2.0.0 run.)
