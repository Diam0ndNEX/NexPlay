# NexPlay

Personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+).
Not a general web browser: everything in here is treated as a game.

## How the owner works
- iPhone only, no Mac or PC. GitHub Actions builds an unsigned IPA; the owner signs it with their own certificate.
- Swift can't be compiled in the Claude environment. If the Actions build fails, the owner pastes the red error lines; fix the first error first.
- Push source changes straight to `main`.
- `.github/workflows/*` can't be pushed from Claude. Give the owner the full file to paste on github.com.
- **Bump the version on every push**, without being asked: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Patch for fixes, minor for features, major for big changes.

## Layout
- `project.yml`: XcodeGen config (the Xcode project is generated in CI, never committed).
- `tools/make_icon.py`: draws the app icon during the build.
- `NexPlay/`: all Swift sources.
  - `Models.swift`: `Game`, `GameEngine`, `OrientationMode`, settings keys.
  - `FileUtils.swift`: paths, MIME types, `GameScanner` (engine detection, titles, sizes).
  - `LibraryStore.swift`: library persistence and import (ZIP, folder, single HTML). Change games only via `store.mutate(id) { ... }`.
  - `NexSchemeHandler.swift`: serves each game at `nexplay://<game-uuid>/...` (own web origin per game, byte ranges, case-insensitive names, symlink-safe, reads on a background queue).
  - `SaveTools.swift`: per-game data stores, save backup/restore/clear through JS.
  - `PageBridge.swift`: injected scripts (diagnostics, key bridge, FPS, RPG Maker runtime with speed/pause).
  - `GameLog.swift`: in-app game log (console, errors, failed file loads) and its viewer. Use it to debug without a Mac.
  - `GamepadOverlay.swift`: on-screen D-pad and buttons.
  - `PlayerViewController.swift`: the game screen and its menu.
  - `LibraryView.swift`, `GameDetailView.swift`, `SettingsView.swift`: SwiftUI screens.

## Rules
- Codable fields added to `Game` later must be optional or have a default, so old libraries still load.
- Compare resolved paths when computing relative paths (iOS reports `/var` as `/private/var`).
- Engine detection: `js/rmmz_core.js` = MZ, `js/rpg_core.js` = MV, otherwise HTML5. The game root can be up to two folders deep.
- Code adapted from Empo / mvmz-apple-mobile (Mateo M., GPL-3.0 with additional terms) keeps its attribution in the file header and in Settings > Credits. Never name this app "Empo".
- Do not override `navigator.getGamepads`: physical controllers reach the game through the Gamepad API here.

## Roadmap
Reference apps: Empo (github.com/mateo-m/empo-app, open source) and RPGPlayer (closed, screenshots only).
- 1.1.0 (done): hardened file server, RPG Maker runtime (speed, pause/resume, focus), desktop mode, sharp pixels option, game log, prompt() dialogs, credits.
- 1.2: NW.js shim (`require('fs'/'path'/'os')`, `nw.gui`, `process`) with saves as real files in the game folder, served by the scheme handler (PUT/DELETE/MKCOL/MOVE/HEAD + directory listing). Gives binary-safe save backup, ZIP export, plugin compatibility. Test 1.1 on a device first.
- 1.3: Controls: movable/resizable on-screen controls, layouts per game and per orientation, haptics, physical controller bindings, portrait position (top/center).
- 1.4: Library: collections, grid/list, bulk delete, Face ID lock for hidden games, automatic save backups, settings search, reset to defaults.
- Later: import 7z/RAR, OGG to M4A conversion at import, in-game text translation.
- Phase 2: RPG Maker XP/VX/Ace. Empo already ships mkxp-z for iOS (`cores/mkxp`, prebuilt core releases fetched in CI), so this is no longer a from-scratch port. Follow its core pattern after Phase 1 is solid.
- Back burner: RPG Maker 2000/2003 (EasyRPG).
