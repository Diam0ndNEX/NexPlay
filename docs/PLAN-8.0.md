# NexPlay 8.0: merge BCD into NexPlay (plan v2)

Copy of the project doc "NexPlay 8.0 Plan - BCD Merge" (owner's answers 2026-11-13), with progress. The owner tests
once all steps are done, then pastes build errors (first error first).

## Progress
| Step | Version | State |
|---|---|---|
| Core merge | 8.0.0 (64) | pushed 2026-11-13, not built yet |
| Design system | 8.1.0 | next |
| Controls | 8.2.0 | |
| In-game | 8.3.0 | |
| Game page | 8.4.0 | |
| itch.io (stores out) | 8.5.0 | |
| Settings and extras | 8.6.0 | |
| Polish and cleanup | 8.7.0 | |

8.0.0 notes: BCD's store (Steam, GOG, Epic, EA), Dock, front-end, update, feedback-upload and JIT-setup files are still
compiled (unreachable: no screen shows them) because ~80 references in ContentView, Library, the game page and Settings
name them. 8.5.0 removes the stores, 8.7.0 the rest. What's New still says 7.8 (8.7.0 updates it).

## Owner's decisions
- **Stores:** itch.io only, for now. Steam, GOG, Epic and EA stay out.
- **Touch controls:** both systems stay, as options. Claude decides how (see Controls below).
- **Design:** where BCD's design is better than NexPlay's, use BCD's. The result must be fluid, smooth, sensible and look excellent, and it must fit every kind of game NexPlay runs (RPG Maker, HTML5, Twine, Ren'Py, Godot, Flash, PC games and the rest), not just PC games.
- NexPlay should do everything BCD does, plus more; reuse almost everything BCD has.

## Goal
One app. BCD's Windows code is built as NexPlay source, not loaded as a separate library with its own screens. NexPlay keeps everything BCD can do and adds more.

## How the merge works
- BCD's app code (`app/Madeira`, tag v0.1.653: 313 Swift files plus the C/ObjC glue) moves into `NexPlay/Windows/BCD/` and compiles into the NexPlay target. GPL headers stay, and the Credits line stays.
- DXMT finds `macdrv_*` with `dlsym(RTLD_DEFAULT)`: NexPlay's executable exports those symbols (from BCD's `madeira-exports.txt`).
- Wine, FEX, DXMT, Mono, the VC runtimes and the d3d12 parts stay prebuilt by `build-windows-runtime.yml`, which then builds only the engine (no BCD app target, no patch script).
- **One JIT and one pairing file:** NexPlay's `JITManager`. BCD's JIT setup, pairing, StikJIT helper and Madeira JIT helper are removed. BCD's launch code checks `CS_DEBUGGED`. `BCDBridge`, `BCDPairingMirror` and `madeira://` play links go away.
- PC games start from NexPlay's library with NexPlay's loading screen.

## Feature map
**Keep (engine and play):** sessions and game files, prefix tools and registry edit, fix-redist and fix-run, VC runtime and Wine Mono downloads, installers (run setup.exe), AutoTune and recommendations (automatic per-game settings), graphics defaults and scan, GPU cards, OpenGL, save backups, auto-save rules and save redirect, external drives and storage, MIDI, logs and log tail, background run and CPU cap, ProMotion, orientation, foldables, controller navigation.

**itch.io:** BCD's `SwiftItch` and `BCDItch` (sign in, owned games, download, install). Games land in NexPlay's library. This is not limited to PC games: itch.io HTML5, Ren'Py and Twine downloads open with NexPlay's own runtimes.

**Drop:** BCD's library, home, launcher and dock screens (NexPlay's replace them), Steam, GOG, Epic and EA, the BCD update check, and log/feedback upload to BCD's servers.

## Controls: both systems, one place to choose
- Every game has **Controls Style**:
  - **NexPlay pad:** today's overlay and layouts. Best for RPG Maker, visual novels and HTML5 games.
  - **PC controls:** BCD's touch system and editor. Best for Windows games and mouse/keyboard games.
  - The default follows the game: PC controls for Windows, Godot desktop and Flash/mouse games; NexPlay pad for everything else. Switch any time in the Game Panel or Game Settings.
- **Extras for both styles,** as add-on items in either editor: gyro aim, aim zone, radial menu, turbo, extra key bar, magnifier, pencil and gesture map. The layout presets (Controller, Point & Click, WASD + Mouse and so on) work in both.
- **Physical controllers:** one system. BCD's `HardwareInput` and controller hub (multiple players, rumble, remapping) are merged with NexPlay's `PhysicalControllers`, for every engine.

## Design: one design system for every game
BCD does these better, so NexPlay takes them:
- **Liquid Glass on iOS 26+,** applied to controls only (bars, buttons, panels), with opaque cards for reading. There's a material fallback below iOS 26 and an opaque fallback when Reduce Transparency is on.
- **Colour profiles** with semantic colour tokens (ground, surface, accent, success, warning, danger). These replace NexPlay's scattered colours, so every screen follows the chosen theme. NexPlay's animated backgrounds stay as an option.
- **Game page, HUD, in-game menu and touch editor:** BCD's structure and layout, NexPlay's content (engine-aware sections).
- **Controller navigation** across all screens.

NexPlay keeps, because its version is better or more general: engine-aware game pages and cards, Game Panel cards, Home shelves, the loading screen with its error card, and Setup Center.

Fixes to NexPlay's current design:
- The pixel font is used only for big titles. Body text, rows and error messages use SF Rounded. Today the Setup Center error and section rows are hard to read in pixel type.
- The tab bar gets a scroll-edge fade, and content insets keep the last rows and footers from sitting under it (Setup Center's footer is cut off today).
- Better placeholder covers for games without art (engine-tinted gradient, title, engine glyph) instead of a single letter.
- Settings and Setup Center use custom glass rows instead of the stock Form look.

Motion and feel: shared spring presets; matched transitions (card to game page, then loading screen, then game); haptics on every key action; no layout jumps while things load (placeholders with fixed sizes); Reduce Motion is respected.

Fits every game type: sections appear by capability (`RuntimeCapabilities`): a Twine game never shows GPU or prefix settings, and a PC game never shows Ren'Py options. One accent colour and icon per engine. All screens tested in portrait and landscape, in both light and dark mode.

## Steps (each one push that builds)
1. **8.0.0 Core merge:** BCD engine and session code compiled into NexPlay, symbols exported, the runtime workflow builds the engine only, NexPlay JIT only, PC games start from NexPlay's library and loading screen. Includes the new runtime workflow file for the owner to paste.
2. **8.1.0 Design system:** tokens, colour profiles, Liquid Glass modifiers, fonts, motion presets and placeholder covers, applied to Home, Library, tab bar, Settings and Setup Center.
3. **8.2.0 Controls:** Controls Style (both systems), shared extras, merged physical controllers.
4. **8.3.0 In-game:** BCD's HUD and in-game menu merged into the Game Panel and Performance HUD, for every engine.
5. **8.4.0 Game page:** BCD's layout with engine-aware sections. Also AutoTune and recommendations, graphics, prefix tools, installers and saves for PC games.
6. **8.5.0 itch.io:** sign in, library, download and install into NexPlay, every engine.
7. **8.6.0 Settings and extras:** BCD settings sections, external drives, foldables, logs, readiness checks in Setup Center.
8. **8.7.0 Polish and cleanup:** transitions, controller navigation everywhere, remove the old bridge, update docs and Credits.
