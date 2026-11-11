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
  - `NexSchemeHandler.swift`: serves each game at `nexplay://<game-uuid>/...` (own web origin per game, byte ranges).
  - `SaveTools.swift`: per-game data stores, save backup/restore/clear through JS.
  - `PageBridge.swift`: injected scripts (key bridge, fast-forward, FPS).
  - `GamepadOverlay.swift`: on-screen D-pad and buttons.
  - `PlayerViewController.swift`: the game screen and its menu.
  - `LibraryView.swift`, `GameDetailView.swift`, `SettingsView.swift`: SwiftUI screens.

## Rules
- Codable fields added to `Game` later must be optional or have a default, so old libraries still load.
- Compare resolved paths when computing relative paths (iOS reports `/var` as `/private/var`).
- Engine detection: `js/rmmz_core.js` = MZ, `js/rpg_core.js` = MV, otherwise HTML5. The game root can be up to two folders deep.

## Roadmap
- Phase 1 (this): RPG Maker MV/MZ and HTML5 games.
- Audio fallback: OGG/WebM may not play on iOS; transcode OGG to WAV in the scheme handler if a game is silent.
- Phase 2: RPG Maker XP/VX/Ace through mkxp-z. Large and risky: no iOS port exists upstream, it needs a C++/Ruby cross-compile on Actions with no local compile.
- Back burner: RPG Maker 2000/2003 (EasyRPG).
