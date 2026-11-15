# NexPlay 8.0: merge BCD into NexPlay (plan v2)

Copy of the project doc "NexPlay 8.0 Plan - BCD Merge" (owner's answers 2026-11-13), with progress. The owner tests
once all steps are done, then pastes build errors (first error first).

## Progress
| Step | Version | State |
|---|---|---|
| Core merge | 8.0.0 (64) | pushed 2026-11-13, not built yet |
| Design system: tokens, profiles, fonts, glass, motion, placeholder covers | 8.1.0 (66) | built OK 2026-11-13 |
| Design system applied: Home, Library, tab bar, Settings, Setup Center | 8.1.1 (67) | pushed 2026-11-13 |
| Controls Style (NexPlay Pad / PC Controls) | 8.2.0 (68) | built OK 2026-11-13 |
| Controls: extras for web games, presets in both styles | 8.2.1 (69) | pushed 2026-11-13 |
| Controls: one controller system (hub, players, rumble, tester) | 8.2.2 (70) | failed: file names used twice (first engine build) |
| Fix: NexPlay's JITPairing.swift and Onboarding.swift renamed | 8.2.3 (71) | pushed 2026-11-14 |
| In-game: shared in-game menu (BCD layout), Game Panel on it | 8.3.0 (72) | built OK 2026-11-14 |
| In-game: Windows panel on the menu, BCD's menu rows, one-Windows-game cards | 8.3.1 (73) | built OK 2026-11-15 |
| In-game: Performance HUD in BCD's HUD layout, every engine | 8.3.2 (74) | built OK 2026-11-15 |
| Game page: BCD's layout, sections by capability, Restart and Play | 8.4.0 (75) | built OK 2026-11-15 |
| Game page: PC sections from BCD (AutoTune, recommendations, graphics, prefix tools, Windows saves) | 8.4.1 (76) | built OK 2026-11-15 |
| itch.io: built as 8.5.0 (77), then removed by the owner (games come from F95zone, imported as files/links) | 8.5.1 (78) | built OK 2026-11-15 |
| Settings: Windows Games page (BCD's engine settings with NexPlay rows) | 8.6.0 (79) | built OK 2026-11-15 |
| Settings: Storage and external drives, logs and diagnostics | 8.6.1 (80) | built OK 2026-11-15 |
| Settings: readiness checks in Setup Center, foldables | 8.6.2 (81) | built OK 2026-11-15 |
| Settings: sub-pages from Forms to glass rows | 8.6.3 (82) | built OK 2026-11-15 |
| Settings: optional helper memory (MadeiraMemoryHost): entitlements fit (get-task-allow only) | 8.6.4 (83) | built OK 2026-11-15 |
| Polish: What's New 8.7, game page again after Close NexPlay, Credits, docs | 8.7.0 (84) | built OK 2026-11-15 |
| Polish: controller navigation in the in-game menu and on the game page | 8.7.1 (85) | built OK 2026-11-15 |
| Polish: card-to-page transition, remove unused BCD front-end files | 8.7.2 | |

8.0.0 notes: BCD's store (Steam, GOG, Epic, EA), Dock, front-end, update, feedback-upload and JIT-setup files are still
compiled (unreachable: no screen shows them). What's New still says 7.8 (8.7.0 updated it to 8.7).

8.1.0 notes: split in two. 8.1.0 adds `NexPlay/DesignSystem.swift` only (no screen uses it yet): `NexTheme`/`NexThemeProfile`
(Nebula default = the old NexStyle violet, plus BCD's Violet, Ocean, Forest, Ember, Rose, Graphite and a custom profile from
one colour; settings `colorProfile`, `colorProfileSeed`), `NexColor` tokens (light-mode variants derived from the dark profile;
`NexColor.dark` for always-dark screens), `NexMetrics`, `NexType` (pixel font only in `display`), `nexGlass`/`nexCard`, button
styles, `NexMotion` + `nexAnimation` (Reduce Motion), `NexHaptics`, `GameEngine.accent`, `NexPlaceholderCover`. `NexStyle`
now follows the profile. 8.1.1 applies it (and adds the profile picker to Appearance).

8.1.1 notes: the app's root font is SF Rounded (`NexType.body` + `.fontDesign(.rounded)`, was the pixel font); the pixel font
stays in navigation titles and `NexType.display`. The game page still sets `.font(.pixel(16))` (LibraryView) until 8.4.0.
Library: engine placeholder covers, token colours and fonts, glass chips (engine chips in the engine colour), row cards,
Continue card, glass selection bar. Tab bar: Liquid Glass, sliding selection, `NexTabBarEdgeFade`, haptics; scroll views
under it use `nexClearsTabBar()` (contentMargins from the `nexTabBarInset` environment value, set on the Settings tab).
Settings home and search: custom glass rows (`NexRowGroup`, `NexNavRow`); the Settings sub-pages stay Forms until 8.6.0.
Setup Center: `ScrollView` with opaque row groups, `SetupRow` = `NexStatusMark` + glass fix button, `ProfileBackdrop`,
explicit rounded fonts (readable when opened from the game page). Background theme Plain = "Colour Profile"
(`ProfileBackdrop`), also used in light mode. Appearance > Colour Profile: profile swatches + Custom Colour.

8.6.0 notes: 8.6 is split in five pushes (table above). 8.6.0 adds Settings › Windows Games (`NexSettingsPage.windows`,
`Windows/WindowsSettings.swift`, a note without the engine) = `NexBCDSettingsView` (`Windows/BCD/NexPlayBCDSettings.swift`,
NexPlay's code): Memory & Performance (status, JIT pool, video memory, swap, what can move, thread sync, eco, keep a game
running in the background, sound meanwhile), Graphics (resolution, frame cap, MetalFX, Direct3D 9, orientation, HUD, hold
refresh rate, OpenGL note), Windows Components (Wine Mono, Visual C++ 64-bit, 32-bit MFC, Wine Gecko: download/cancel/remove),
All Engine Options (bcd.cfg catalog, search, per-option page). Everything goes through BCD's live backends
(BCDMemoryLive, BCDGraphicsLive, BCDDotNetLive, BCDVCRuntimeLive, BCDGeckoLive, BCDAllSettingsLive); no BCD file changed.
Left out: background store downloads, helper memory and its test (8.6.4), BCD's accounts/JIT/Dock sections.

8.6.1 notes: Windows Games › Storage & Drives (`NexBCDStoragePage` over BCDStorageLive: free space, back up every Windows
save to a zip (share sheet, deleted after) and restore one (copied out of the picker first, asked 0.5 s after it closes),
external drives (add a folder or drive in Files = a Windows drive letter + C:\External\<name>, reconnect, remove), shared
files with Clear) and Logs & Diagnostics (`NexBCDLogsPage` over BCDLogsLive: share the engine's logs, recent logs, extended
logging, BCD's diagnostics switches, performance trace, AutoTune after a crash, Windows screenshots to Photos). One
fileImporter with a mode. Left out: sending logs to BCD's server, Add every game / Find games / Steam installs (they add
to BCD's own library, which NexPlay doesn't show). Not built: playing a NexPlay game from an external drive.

8.6.2 notes: Setup Center (engine builds) gets `NexBCDReadinessSection` (`Windows/BCD/NexPlayBCDReadiness.swift`): Windows
Components rows (Visual C++ 64-bit, 32-bit MFC, Wine Mono, Wine Gecko; state, progress and Download from the row; MFC and Mono
turn amber only when a game needs them) and Windows Games Check (BCD's `BCDReadiness.scan`/`evaluate` on each Windows game's
folder in the background, up to 40 games, games with notes first). `LibraryStore.current` (weak, set in init) gives it the
library without an environment object. Windows Games › Graphics shows BCD's foldable switch on the foldable iPhone only
(`NexBCDFoldableRow`); BCD's Duo interface switch is left out (it changes BCD's screens, which NexPlay doesn't show).

8.6.3 notes: `NexFormStyle.swift`: `NexForm`/`NexList` = Form/List with rows on the profile's surface (NexMenuSection's card
colour), profile hairlines, rounded type, accent tint, no stock grey (a Group passes listRowBackground/listRowSeparatorTint to
every row). Every Settings sub-page Form (Appearance, Controls, Gameplay, JIT, Translation, Privacy, Import & Backup,
Advanced, Diagnostics, Engines, controller mapping), Storage and Credits, plus Game Settings and Edit Button use them.
`SettingsHeader` = the design system's small-capitals title; `SettingLabel`/`ValueSlider` use NexType/NexColor. Controls
are unchanged (same toggles, pickers and links), so no setting moved.

8.6.4 notes: BCD's MadeiraMemoryHost (v0.1.653: Info.plist on com.apple.ar.viewer, entitlements = get-task-allow only, which
the owner's profile grants) is the app extension target `NexPlayMemoryHost` (`NexPlayMemoryHost/`: BCD's MemoryHost.m with the
header path changed, Info.plist "NexPlay Memory", entitlements), bundle id com.nexplay.app.MemoryHost (BCD's MemoryPool.m finds
`<app id>.MemoryHost`), embedded in every build; `tools/ci/package_extras.sh` writes its entitlements with ldid (no workflow
change). Windows Games › Memory & Performance shows Helper Memory (mempool-mb, off by default; per game through the game's
config) and Test the Helper's Memory. If the signing app drops the extension, the test says "No extension" and helper memory
stays off.

8.7.0 notes: 8.7 is split in three (table above). 8.7.0: `WindowsPendingPlay` (WindowsGames.swift: the game id + time in
UserDefaults `windowsPendingPlay`, written by both Close NexPlay buttons (error card, game page) before exit(0); LibraryView's
start task opens that game's page if NexPlay is opened again within 30 minutes, before onboarding/What's New). What's New is
8.7 (eight 8.x items, design-system fonts and button). Credits name NexPlay 8's BCD parts and the memory helper. The old
bridge (BCDBridge, BCDCore.framework, patch script, madeira:// links) was already removed in 8.0.0; only history comments
mention it; `tools/windows/run_bcd_ci.py` is still the runtime workflow's builder and stays.

8.7.1 notes: `NexPlay/NexMenuNavigation.swift`: `NexMenuNavigator` (rows in draw order through `NexMenuOrderKey`, actions
and slider steps registered by `.nexMenuFocusable(id, token:, enabled:, step:, action:)`; `capture()` saves every connected
controller's element handlers and installs its own, `release()` puts them back, so the game (PhysicalControllerManager) and
the library (LibraryController) get their handlers back when the menu or page closes). D-pad/left stick: up/left back, down/
right on (left/right step a focused slider), A press, B back (question, page, close), L1/R1 tabs, Menu close; the ring shows
only after the first controller press. NexInGameMenu (Game Panel, Windows panel) owns one (rows, toggles, chips, sliders,
question answers focusable; ScrollViewReader keeps the ring in view). GameDetailView owns one with `autoFocusFirst` (Play is
focused, so A plays as in 7.8.0): main button, chips, note fixes, the cards' rows; B closes the panel then the page; L1/R1
switch the panel's pages. Not covered: rows inside the panel's Form pages (Options), Windows games' own controller reading
in the engine (a press can still reach the game while the Windows panel is open).

## Owner's decision of 2026-11-15
- **No itch.io.** The owner gets games from F95zone and imports them (files, folders, Download from Link). 8.5.0 added an
  itch.io store; 8.5.1 removes it again (reverted). No store screen, sign-in or Settings row for any store (itch.io, Steam,
  GOG, Epic, EA, Dock) appears in NexPlay; BCD's store code stays compiled, untouched and hidden (BCD updates stay easy).

## Owner's decisions of 2026-11-13 (second round)
- **Other stores stay in the code, hidden** (replaces "Drop Steam, GOG, Epic and EA" below). Reason: BCD updates. An
  update re-copies BCD's app/Madeira and re-applies NEXPLAY-CHANGES.md; every BCD file we edit is a file to merge by
  hand each time, and removing the stores means ~80 edits in the files BCD changes most (ContentView, Library, the game
  page, Settings). So: no store screen, sign-in or Settings row for Steam/GOG/Epic/EA/Dock appears in NexPlay; only
  itch.io is shown. Their code stays compiled and untouched, so a later "show Steam" is a small change.
  Rule for every 8.x step: change BCD files as little as possible; put NexPlay's behaviour in NexPlay files or in small
  hooks, and list each BCD edit in NEXPLAY-CHANGES.md.
- **Helper memory (BCD's MadeiraMemoryHost extension):** Claude's call. Plan: 8.6.0 adds it as an optional second
  extension, off by default (BCD's `mempool-mb` per game), only if its entitlements fit the owner's certificate;
  skipped otherwise. It lends big games extra RAM: the extension reserves memory, hands it over and quits, and memory
  owned by a quit process doesn't count against NexPlay's limit.
- **One Windows game per app launch stays** (Wine runs as threads inside NexPlay; iOS can't start a new process, so
  only quitting the app resets Wine). Ideas around it instead:
  - 8.3.0: the second-game case is an error card with a clear message and a **Close NexPlay** button; Play buttons
    of other Windows games say "Restart NexPlay to play" once a Windows game ran this launch (library card, game page).
  - 8.3.0: Quit Game in the Windows panel and BCD's menu warns that another Windows game needs a restart.
  - 8.4.0: games that only need a restart after an installer (setup.exe, redistributables) get a "Restart and Play"
    hint, so installing and playing is understood as two launches.
  - 8.7.0: when NexPlay comes back after the owner swiped it away, a Windows game started from the error card's
    "Close NexPlay" can open its game page again (a pending-play note saved before exit(0)).
  - Web, Ren'Py, Godot, Flash, EasyRPG games are not affected and can still be played after a Windows game.

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

8.2.0 notes: split in two. 8.2.0 = Controls Style only: `Game.controlsStyle` (nil = Automatic), pickers in the Game Panel,
Game Settings and the Windows panel; PC Controls over web games = BCD's touch layer and editor (shared BCD layouts, engine
builds only; without the engine the pad is used); NexPlay Pad over Windows games (BCD's controls hidden). BCD's files are
unchanged (NexPlay's code is `ControlsStyle.swift` and `Windows/BCD/NexPlayPCControls.swift`). Using PC Controls in a web
game creates BCD's LibraryModel (as a Windows game would). 8.2.1: the extras (gyro aim, aim zone, radial, turbo, extra key
bar, magnifier, pencil, gesture map) in both editors, layout presets for PC Controls, and HardwareInput + controller hub
merged with PhysicalControllers.

8.2.1 notes: split again. 8.2.1 = extras for web-view games with either style (NexPlay's own code in `Extras.swift` and
`ExtrasLayer.swift`, ideas from BCD's round 603/604 extras; works without the engine): key bar, radial menu, turbo, gyro aim,
aim zone, gestures, magnifier, Pencil; opened from the Game Panel, the NexPlay Pad editor's + menu and Game Settings (BCD's
editor is unchanged, so it has no Extras entry). Windows games keep BCD's own extras (in-game menu). Layout presets now
work in both styles (PC Controls: converted to a BCD touch layout) and in the Windows panel. 8.2.2: BCD's HardwareInput and
controller hub merged with PhysicalControllers.

8.2.2 notes: "merged" as one NexPlay system on top of both, not a code merge: BCD's HardwareInput/GamepadInput/hub stay
unchanged and keep running Windows games (XInput slots, rumble, controller-as-keyboard in BCD's in-game menu); replacing
them would mean rewriting BCD's input path. NexPlay's `NexControllerHub` (Controllers.swift, ideas from BCDControllerHub)
gives every engine player order with player lights, rumble for web games (Gamepad API vibrationActuator shim → the pad's
haptics), Only Player 1 Presses Keys, battery and a live tester (Settings > Controls > Controllers). Gamepad-index-to-pad
matching for web rumble follows connection order and can be wrong after Make Player 1.

8.3.0 notes: split in three. 8.3.0 = `NexPlay/NexInGameMenu.swift` (NexPlay's code on the 8.1 design system, BCD's
BCDInGameMenu layout: panel over the dimmed game, docked leading in landscape / bottom in portrait, eyebrow + title + close,
tabs, sections of rows in cards, pages that push in, questions inside the panel; `NexMenuHostingController` =
overFullScreen, the game's orientation) and the Game Panel rebuilt on it (tabs Game, Display, Controls, Tools; sections by
engine; Display has Power and the Performance HUD toggle/corner/detail). No BCD file changed. Not yet: controller
navigation in the menu (8.7.0). 8.3.1: the Windows panel on NexInGameMenu with BCD's session menu rows
(BCDSessionMenuSource) in NexPlay's look, the second-Windows-game error card + Close NexPlay, "Restart NexPlay to play",
Quit Game warning. 8.3.2: BCD's HUD (BCDHUDView/BCDHUDCore) merged with PerformanceHUD for every engine.

8.3.1 notes: one menu for Windows games. BCD's menu still opens and closes as before (menu button, controller chord,
LibraryModel.menu), but BCDSession.swift no longer draws BCDInGameMenu (hook `NexBCDMenu.replacesBCDMenu`);
`NexWindowsSession` sends `.menu(open)` and WindowsLaunchController shows `WindowsPanelView` (now on NexInGameMenu) with
BCD's live source rows (`NexPlayBCDMenu.swift`: every row kind, pages, log page, questions; BCD's touch section and
touch-look sample are BCD's own views inside a row) plus NexPlay's sections (Performance HUD, Controls Style, Edit, Layout
Preset, Copy Log). BCD's Quit question adds the one-game-per-launch line. A second Windows game shows "Restart NexPlay to
play" with Close NexPlay (exit(0)) and Back to Library; `WindowsEngine.ranThisLaunch` makes the game page's Play button and
the library context menu say "Restart NexPlay to Play". Not yet: controller navigation inside the panel (BCD's commands
reach no view now; Back + Start still closes it), BCD's row thumbnails (Windows page) show the symbol instead. The classic
desk menu (BCDDeskSessionMenu, touch-controls window) still draws BCD's own panel.

8.3.2 notes: one Performance HUD. NexPlay's plate (PerformanceHUD.swift) takes BCD's structure: layouts Pulse, Strip,
Tune, Report (`HUDLayout`, setting `hudLayout`, replaces hudDetail; BCD's 1-4) and six places (`HUDPlace` in hudCorner:
+ Top, Bottom). Web games: the page's stats script also sends the longest frame of each second (Report's "worst"); low =
lowest FPS of the graph window (15 s / 30 s), not a true 1 % low. Windows games: Show Stats turns on BCD's own HUD in the
chosen layout (`NexBCDHUD`, as BCD's menu does it), so the engine's real frame times, GPU and JIT pool show; BCD's HUD rows
(Custom, place, dimming) stay in the panel's Display tab. Settings, Game Panel > Display and the Windows panel all use the
same layout and place. Not built: BCD's Custom layout and dragging for web games, BCD's calm dimming for web games.

8.4.0 notes: split in two. 8.4.0 = GameDetailView rebuilt in BCD's BCDGamePage structure (art across the screen with
BCD's gradients, name + badges + Play and chips low on the left, Details (facts) and How It Runs cards on the right; upright
phone: art on top, one column; Options/Saves/Media/Mods open in a panel from the right, or from the bottom upright, with
page chips and close). Sections by `RuntimeCapabilities` (new flags fileSaves, mods, rpgMakerOptions, engineRuntimes,
webOptions, pcSetup), also in Game Settings (RPG Maker, engine runtime, Windows, mouse, Block Internet). Notes under the
actions: runtime notice, crash card (Use <runtime> / Dismiss), installers. PC games: Run Installer (`WindowsInstallers`
in WindowsGames.swift: setup/vcredist/DirectX/PhysX/redist .exes; runs once in place of the program, kept in memory), then
"Restart and Play" (main button + note, Close NexPlay = exit(0)). Pixel font gone from the game page (LibraryView) and
GamePages (titles rounded). No BCD file changed. Not yet: matched card-to-page transition (8.7.0), controller focus on
the page (8.7.0). 8.4.1: BCD's PC sections (AutoTune, recommendations, GPU cards, prefix tools, BCD's saves) through a
NexPlay file in Windows/BCD.

8.4.1 notes: PC Setup (game page chip and panel page, PC games with the engine built in):
`Windows/BCD/NexPlayBCDGamePage.swift` (NexPlay's code) draws BCD's game page data with NexMenu rows: BCDGameDetailSource's
backend (BCDGamePageLive) gives the sections (Display, Direct3D/GPU cards, Compatibility, Windows/prefix tools, Components
(redistributables), CPU translation, Where the saves live, Game fixes, Wine desktop, Controls and binds, input extras,
Launch, Sound/MIDI, Save backups, Help) and does every change (`set`), plus Recommended Settings (use, get the latest list),
AutoTune (toggle, undo, keep findings; Turn On when off globally) and the game's config text. `NexBCDGamePage.entry` finds
BCD's library entry for the game's program (made with the drive link when the drive is set up; before the first Windows
start it says so). Hidden: Steam, DLC, Version, Download, Library, Location (stores hidden; NexPlay's Options do name, cover,
removal). Not drawn: rows that open BCD's store search, cover/wallpaper pickers or Workshop. No BCD file changed.

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
6. **8.5.0 itch.io:** sign in, library, download and install into NexPlay, every engine. The other stores stay in the code, hidden (no screen).
7. **8.6.0 Settings and extras:** BCD settings sections, external drives, foldables, logs, readiness checks in Setup Center; optional helper memory (MadeiraMemoryHost) if its entitlements fit.
8. **8.7.0 Polish and cleanup:** transitions, controller navigation everywhere, remove the old bridge, update docs and Credits.
