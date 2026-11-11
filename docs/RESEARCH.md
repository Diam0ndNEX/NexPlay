# Research digest

What the reference apps do, as of 2026-11-11. Read it before each part. Sources are listed per section. Re-check them: they change. This file has facts and ideas only; no copied code.

## Empo (github.com/mateo-m/empo-app, GPLv3 + additional terms, v0.11.0)
Runs RPG Maker XP/VX/Ace (mkxp-z core), MV/MZ (web view core), Pokemon Essentials, PSDK games. iOS 26+. Sideloaded. Parts: `cores/` (mkxp, mvmz, psdk wrappers around prebuilt core releases), `ios/Empo` (app), `ios/GameProbe` (Swift package for INI/script probing), `docs/`.

### Import (docs: `ios/Empo/docs/import-pipeline.md`)
- A game is a directory. One container per title (named after the INI title, sanitized). No database.
- Inputs: folders, `.zip`, `.7z`, `.rar` (libarchive streaming), `.jgp` (JoiPlay bundle), self-extracting `.exe` (CAB via libmspack, 7z/rar via offset callbacks), Enigma Virtual Box `.exe`.
- Picker uses `asCopy: true` (disposable tmp copy; also works with naive resigners).
- Stages: stage-source, probe (one selective walk pulling INI, scripts, exe, title art into scratch), root choice sheet (Add Games / Already in Library), plan, extract once, move deepest root first, finalize (metadata, script profile, icon), merge into library without a full rescan.
- Updates in place: merge new files into an APFS-cloned staging copy and swap atomically; saves protected; collisions archived as `.empo-displaced.bak`; crash leftovers swept (restore the merged staging tree or backup before sweeping).
- Invariants: zip-slip check by path components (a filesystem prefix check false-positives on device: `/var` vs `/private/var`); cancellation flag checked everywhere; out-of-space mapped to a clear error; in-flight guard before any container exists; no half-imported card; permissions normalized after each move.
- Cards show progress and artwork mid-import (exe icon first, never title-screen previews that flash).
- RTP-dependent games are warned about before start; cannot install RTP.
- Titles decoded from CP1252 INI; mojibake folder names migrated.

### Saves (docs: `saves.mdx`, `troubleshooting.mdx`)
- Saves live in the Files app (Show in Files). Two places: shared `Data/<game>/` and portable (inside the game folder).
- Update keeps saves; delete moves portable saves to `Rescued Saves/<title>/`; re-import moves them back.
- Deleting the app deletes the sandbox: warn the user.
- A past bug renamed saves; recovery sheet restores the newest save at launch.
- Save formats are the same as on Windows and JoiPlay: copy files in and out.

### Backups (docs: `backups.mdx`; code `ios/Empo/src/Backup`)
- Targets: iCloud Drive (needs entitlement), Dropbox, Google Drive, S3, WebDAV (the cloud ones are behind "Empo Plus"). Export/import ZIP needs no target.
- Per game: whole game (if under 750 MB) or saves+settings only; also app settings and layout profiles.
- Triggers: stop playing, background, 30 s after launch, nightly when charging. Not while a game runs, restoring, device hot, Low Power Mode, Low Data Mode; Wi-Fi only by default.
- Retention presets: Less (5 last + daily 3d + weekly 2w), Standard (10 + 7d + 4w), More (20 + 14d + 8w). Storage limit per target. Pause per target.
- Library card warns after 7 days without a backup; banner after 3 weeks.
- Restore keeps current saves as `.empo-displaced.bak`; restore on a new device flow; restore into a different game; undo settings restore for 7 days; sync settings between devices.

### Player (docs: `playing.mdx`)
- Overlay: D-pad (or joystick style) and action buttons; toolbar with Show keyboard, Edit controls, Hide controls, More.
- Edit mode: drag, size, opacity, label, delete; add button (Empo action or any key; max 21 per orientation); undo; reset; grid snap; drag and resize the game screen with corner grabbers. Portrait and landscape have separate layouts.
- Layout profiles: named, any game; "Automatic" chain: game `controls.json` → default profile → built-in. Profiles also place the game on screen. Settings > Gameplay > Layout profiles.
- `controls.json` manifest a game can ship (JSON schema in `docs/schemas`, guide `docs/controls-format.md`, 128 KiB cap); Empo also translates JoiPlay `gamepad.json` and Kirin `kirin-touch-controls.json`.
- Multi-touch controls; press delivered on touch-down via UIKit capture; held keys refcounted so shared-key controls release correctly; d-pad resolves to cardinals near center; sticks read as eight sectors.
- Controllers: four-layer map resolution (built-in, profile, game, user), per-game or global scope, controller buttons can trigger Empo actions (fast forward, pause); basic/micro profile controllers; controllers that reach iOS as keyboards; reserved buttons (Home, Guide) never reach the game.
- Soft keyboard accessory bar for games that ask for typing; keyboard does not resize the game view.
- More sheet: Show cheats, Fast forward (2-9x slider per game), Diagnostics overlay, Controller buttons, Layout profile, Pause, Quit (confirm).
- Pause: manual (back to library with a frozen frame, card shows pause indicator, tap to resume with hero zoom) and background (engine stops, player stays mounted). MV/MZ: runtime.js freezes rAF callbacks, suspends Web Audio, pauses media, snapshots with `takeSnapshot`; on resume reset `SceneManager._currentTime`. Ruby cores block the game thread on a condition variable and pause OpenAL sources individually (never touch the AL context: it blips).
- Diagnostics overlay: FPS graph (scaled to the game's frame cap), memory, engine details. Optional "Fill unused screen area" colour; "Show touch area".
- Touch acts as mouse (XP/VX/Ace), on by default.
- Per-game settings (long press): display (smooth scaling, fixed aspect, font scale, solid fonts), layout profile, performance (frame skip), engine (postload scripts, path cache, in-game keyboard, touch as mouse, JoiPlay compatibility, network access), gameplay (fast forward). Each row says "Changed by you" and can reset to the game's value; settings split into restart-required and runtime.
- Network per game (off simulates airplane mode), CA bundle refreshed weekly.
- Other: respect silent mode setting, interface haptics, controller haptics, MIDI sound set import (`.sf2`, `gm.dls`; bundled GeneralUser GS), What's New sheet after an update, hints/tips, update checker (public releases), error reports (opt-out) and per-session debug logs with keep-last-N, crash tracker, language picker (9 languages), theme dark/light/system, build info sheet (commit, branch), licenses screen generated from each core's `licenses.json`.

### Library
- Grid or list; title inside/under card; Continue playing hero card; search; 10 sort options (title, added, played, play time, size); select multiple; context menu Info / Settings / Select multiple / Delete; game info sheet; artwork cache and off-main decoding; duplicate games moved to `Duplicate Games/`.

### mkxp-z / cores
- Core contract `GameCore.h` (`gamecore_*` functions) implemented by each core (mkxp, psdk, mvmz). Cores are prebuilt releases pinned by version and SHA-256 and fetched by a script. Seven Ruby versions in one app; each game runs on the version it was written for. Ruby games: one per app launch (iOS), Ogg/Theora movies only, Windows-only API calls partly emulated (`win32_wrap.rb`), case-insensitive file lookup, saves routed to the data folder, JoiPlay compatibility toggle, touch-as-mouse bridge. Fast-forward and pause are engine calls. libretro docs list engine facts: XP runs at 40 FPS, 640x480; VX/Ace 60 FPS, 544x416; RTP folders named Standard / RPGVX / RPGVXAce.

### MV/MZ core details (mvmz-apple-mobile)
- Desktop Mac user agent so MV asks for the right audio, keeps its fixed update rate, and MZ uses full height.
- NW.js shim (`require`, `process`, `nw`) so saves go to files in the game folder; `process.cwd()` returns `/` (MZ stops if it starts with `/private/var`).
- File server over a custom scheme with case-insensitive lookup, realpath containment, byte ranges; GET/HEAD/PUT/DELETE/MKCOL/MOVE; the game root is read-only.
- `Document.prototype.hasFocus` returns true; rAF wrapped for pause and speed; MZ speed via `determineRepeatNumber`, MV via `_deltaTime`.
- Simulator-only: Ogg reported playable but fails: force `.m4a`.
- Web view must sit in a visible window or WebKit suspends the page.
- Prompts/alerts/confirms routed to the app; web content process termination ends the game with an error.

## RPGPlayer (closed, App Store id6754986970, $6.99, iOS 17.6+, v2.3)
XP/VX/VX Ace/MV/MZ with a dual-core engine. Features named in its listing and screenshots:
- Full gamepad UI navigation of library, collections and settings; "Game Mode" vs "UI Mode" switch; Xbox/PS/MFi/Backbone controller support; native virtual keyboard for mkxp-z games; Pokemon input fixes.
- Library collections (custom folders), colours for games and collections, drag & drop reorder in list and grid, iPad widgets.
- Rewritten save system: save management screen with backup and import; storage manager with overview and per-game sizes; plugin manager (enable/disable game plugins); one-tap import; hardware-accelerated imports; report-a-problem form with game picker; customizable haptic virtual gamepad.
- Smart fix of garbled filenames for 13+ language families.
- Settings tree (from the owner's screenshots): search, profile card, Support (donate, Discord), Appearance (theme, background, library layout, language, app icon), Controls (virtual gamepad, control bar, haptics, physical controllers), Gameplay & Performance (orientation, VSync, portrait position, native engine visuals), Translation & Engines (in-game text translation), Privacy (hide games and collections behind Face ID/Touch ID/passcode), Import & Backup (media conversion, iCloud sync, automatic save backups), About (version, platform, Show Tips Again), Reset to Defaults. Dark space background, large rounded cards, coloured icon tiles, pixel-style title font, floating close button.

## ArkRPG (closed, App Store id6757788340, 2026)
iOS/iPadOS RPG Maker player. Smart encoding recognition for gibberish names (ZIP import fix for mixed GBK/Shift-JIS); iCloud save sync across devices; MTool translation file support (`TranslateFile.json`, machine or manual translations, one tap to mount, also translates titles); custom virtual pad (layout, size, opacity); multilingual UI; all data local. Known: occasional "reload" when the web page is killed for memory; developer is tuning memory loading.

## Others
- QuestPlay (free, IAP, MV/MZ, iOS 18.4+): button remapping with extra keyboard keys, direct folder import, native save/load stored inside the game folder, honest compatibility note for desktop-only plugins.
- Runa (free): MV/MZ web runtime + XP/VX/Ace native runtime; engine auto-detect; library search, filter by engine, sort by name/recently played; remappable, movable, resizable virtual gamepad; per-game settings saved automatically; export/import saves as ZIP.
- RPGEmu: MV/MZ/XP, virtual keyboard for visual novels, SwiftUI library, import by ZIP, demo game included.
- XP Pocket: XP/VX/VX Ace only, local import.
- JoiPlay (Android): plugin-based; RPG Maker MV plugin editor (enable/disable plugins), game edit (name, version, icon), invalidate missing games, backup/restore, compatibility list, content filter, `game.cfg` patches, built-in `fs` module for NW.js behaviour, NW.js-mode saves forced into the game folder (`save` or `www/save`), custom fonts, opus support.
- EasyRPG Player: RPG Maker 2000/2003; translation redirects text files (Save, Translation, Game directory order). Not planned.

## Ideas worth copying (summary)
Pause with frozen frame; save rescue on delete; `.displaced.bak` convention; update in place with a swap; atomic everything; shared-key refcount in controls; 8-sector sticks; per-game settings with "changed" markers; plugin manager; cheat menu; storage manager; collections with colours; encoding repair; MTool dictionary; keep-last-N logs; "restart required" flag on settings.
