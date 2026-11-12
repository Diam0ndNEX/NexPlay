# NexPlay 7.0 "Everything" — plan and spec

Written 2026-11-12 for the chat that builds it. Repo: Diam0ndNEX/NexPlay (main). Current version 6.1.1 (build 30).
First commit of the build chat: copy this file to `docs/SPEC-7.0.md` and add a pointer to it at the top of CLAUDE.md.
All rules in CLAUDE.md still apply (iPhone-only owner, no local compile, owner pastes workflow files, bump the version on every push, fix the first build error first, short replies).

**`docs/SPEC-7.0-review.md` overrides this file where they differ.**

## 0. Owner facts that shape the plan
- Device: **iPhone 17 Pro Max** (A19 Pro, 12 GB RAM). Runs iOS 26 or later, so it is a **TXM device**: JIT needs the iOS 26 "script/helper" path, not the old simple attach. Confirm the exact iOS version from the app log (`UIDevice.current.systemVersion`) before choosing code paths.
- Signs IPAs with a signing app and a certificate that has **get-task-allow**. Already uses Madeira, Iridium and BCD with JIT, so knows pairing files and LocalDevVPN.
- Wants everything: built-in JIT, a Windows PC game runtime (Madeira/Iridium/BCD), stores, and a major UI/UX overhaul that fits all of it. No scope limit.

## 1. Goal
One app that runs every game the owner has:
- **Native paths, unchanged and preferred:** RPG Maker MV/MZ, HTML5, Twine, Construct, Tyrano, Godot (GDScript), Ren'Py web, Flash, mkxp (XP/VX/Ace).
- **New Windows path:** any Windows game (.exe) through **Wine + FEX-Emu + DXMT**, taken from **BCD** (Madeira fork). Covers Godot C# (Paper Lily), Unity, GameMaker, WOLF RPG, KiriKiri, NScripter, RPG Maker 2000/2003/XP/VX/Ace Game.exe, Ren'Py desktop, XNA/MonoGame, and real PC games.
- **Built-in JIT:** pairing file + LocalDevVPN, enable JIT from inside NexPlay.
- **Stores (later phase):** Steam and GOG, from BCD.
- **A UI that makes this feel like one product**, not features bolted on.

## 2. Sources to study and copy (standing permission: check LICENSE, keep attribution in file headers and Settings > Credits)
| Project | What to take | License |
|---|---|---|
| BCD — github.com/thebcd69/bcd-games | Main base: Windows runtime build (`.github/workflows/build-ipa.yml`, `build/`, `tools/`), built-in JIT helper, controller hub, touch controls ideas, per-game settings + `recommended/` database + auto-tune, D3D12 runtime (`madeira-d3d12`), BCD Dock (Steam), GOG | GPL-3.0 + Madeira Converter Exception; BCD files GPL-3.0-only; **attribution required on About/Credits** |
| Madeira — github.com/willfaust/Madeira | Original runtime, docs on how FEX/Wine/DXMT fit together on jailed iOS | GPL-3.0-or-later; FEX/DXMT forks MIT upstream + GPL mods |
| Iridium — github.com/intraducine/iridium | iOS 18/26 JIT handling (PRs #18, #95, #101: built-in StikJIT, LiveContainer JIT), graphics options, manual Actions workflow | AGPL-3.0-only (original code) |
| StikDebug — github.com/StephenDev0/StikDebug | Pairing-file JIT through idevice, TXM scripts (`universal.js`) | AGPL-3.0 |
| idevice (jkcoxson) | Talks to the device's lockdown/debugserver over LocalDevVPN | check license |

Notes:
- **Read before writing.** First read BCD's `app/` (Swift side), its JIT helper and `build-ipa.yml` (2,669 lines). The workflow has `if: github.repository == 'thebcd69/madeira-bcd'`: remove that condition when copying. It keeps the Metal Shader Converter installer in a draft release; NexPlay must download Apple's installer itself in CI and never commit it.
- **Pin versions.** Prefer each BCD release's `BCD-source.tar.xz` (full source + submodules at pinned versions) over live submodules. Record the tag in `tools/windows/runtime.version`.
- **Licensing consequence.** NexPlay stays private, so GPL/AGPL is fine. Add a LICENSES/ folder and a Credits section listing every project. Note in CLAUDE.md that sharing NexPlay publicly would require publishing its source.
- **Not shipped.** The Microsoft VC++ runtime DLLs are not shipped (BCD doesn't either). The owner imports redistributables (see 5.6).

## 3. Architecture changes (do these first, they make everything else fit)
### 3.1 Runtime registry
Replace scattered `engine.isRPGMaker / isWebGame / isRuby` branching with a registry:
```swift
enum RuntimeKind: String, Codable { case web, ruby, windows }   // how a game is run
struct RuntimeCapabilities { needsJIT, saveStates, gameSpeed, pause, touchMouse, cheats, ... }
protocol GameRuntime { kind; capabilities(for: Game); prepare(game) async throws -> RuntimeLaunch; makeScreen(...) -> UIViewController }
```
- `GameEngine` keeps describing *what the game is*: add `.windows`, `.unity`, `.gamemaker`, `.wolf`, `.kirikiri`, `.nscripter`, `.rpg2k`, `.rpg2k3`, `.godotDotNet`, `.xna`. All `switch`es stay exhaustive.
- New optional `Game` fields (Codable defaults, per CLAUDE.md rules):
  - `runtime: RuntimeKind?` (nil = automatic)
  - `exePath: String?`
  - `prefixID: String?`
  - `windowsSettings: WindowsGameSettings?`
  - `compatibility: CompatStatus?` (untested/works/playable/broken)
  - `source: GameSource?` (imported/steam/gog)
  - `storeID: String?`
- `GameScreen.swift` already picks web vs Ruby; extend it to the registry, adding `WindowsGameRunner` beside `RubyGameRunner`.

### 3.2 Feature modules and build flags
- Build flags in `project.yml`: `NEXPLAY_MKXP` (exists), **`NEXPLAY_WINDOWS`**, **`NEXPLAY_STORES`**. Without a flag, the code compiles a stub that says "not in this build", so the fast build keeps working.
- **Load the heavy runtime by `dlopen`, like mkxp:**
  - Load `Frameworks/NexWindows.framework` (Wine unix side, FEX, DXMT, BCD glue) and the Wine data (`NexPlay.app/WindowsRuntime/`: Windows-side DLLs, fonts, prefix template).
  - Keep it out of the Swift module graph.
- **One Windows game per process launch, if Wine/FEX need it** (mkxp already works this way). Exiting a Windows game asks to relaunch NexPlay. Check whether BCD needs this; copy its behaviour.

### 3.3 Entitlements
Add `NexPlay/NexPlay.entitlements` and `CODE_SIGN_ENTITLEMENTS`:
- `get-task-allow` = true
- `com.apple.developer.kernel.increased-memory-limit` = true
- `com.apple.developer.kernel.extended-virtual-addressing` = true (FEX/Wine need a large address space; BCD relies on GetMoreRam for these)

The CI build is unsigned (`CODE_SIGNING_ALLOWED=NO`), so the entitlements file isn't embedded automatically:
- Add a CI step that runs `ldid -S NexPlay/NexPlay.entitlements` on the app binary (`brew install ldid`). Most signing apps keep or merge binary entitlements.
- Show the active entitlements in Settings > Diagnostics: read `get-task-allow` via `SecTaskCopyValueForEntitlement`, plus whether memory limits are raised (`os_proc_available_memory`). The owner can then see whether the signing app kept them.

## 4. Phase 1 — Built-in JIT (version 6.2.0) — testable alone
### 4.1 How it works (copy from BCD's helper, fall back to StikDebug's approach)
1. **Pairing file.** Imported once from Files: `.mobiledevicepairing` / `.plist`, the same one SideStore uses (`ALTPairingFile.mobiledevicepairing`). Store it in the Keychain, not in Application Support.
2. **LocalDevVPN.** It must be on, with Wi-Fi.
   - NexPlay checks that the tunnel answers (copy the address/port check from BCD/StikDebug) and shows "Turn on LocalDevVPN" with a button that opens the app by URL scheme, if it has one.
3. **Connect and attach.** NexPlay uses idevice to connect to lockdown, start the debug service, and attach to its own PID.
   - **TXM (iOS 26+ on A15+, the owner's case):** follow BCD's built-in helper. The helper runs the iOS 26 JIT dance (StikDebug's `universal.js` logic) for NexPlay's own process. The Windows runtime's JIT allocator (FEX) must use the memory mapping that this path provides. BCD's FEX fork already does this; keep its allocator and don't use stock FEX.
   - **Non-TXM:** a plain attach and detach sets CS_DEBUGGED, and then `mmap(RWX)` / `MAP_JIT` works.
4. **Detect JIT.** Check with `csops(getpid(), CS_OPS_STATUS)` for the CS_DEBUGGED flag, and also run a test that maps an executable page and runs a tiny function. Show the result.
5. **Fallback.** If the built-in helper fails, offer "Enable with StikDebug": open `stikjit://enable-jit?bundle-id=<NexPlay bundle id>` (check StikDebug's current URL scheme) and return.

### 4.2 Behaviour
- Settings toggle: **Enable JIT automatically when a game needs it** (default on), plus **Enable JIT at app launch** (default off).
- JIT lasts for the process lifetime. If a Windows game is started without JIT, the JIT sheet appears (see 8.5).
- Log everything to AppLog with a `jit:` prefix: each step, the error text, TXM yes/no, the iOS version.

### 4.3 UI
Settings > **JIT & Performance** page:
- Status card: JIT on/off, TXM/non-TXM, VPN status, pairing file present, entitlements check.
- Buttons: Import Pairing File, Enable JIT Now, Test JIT, Remove Pairing File.
- A first-time setup wizard (see 8.2).

### 4.4 Test on device
Import the pairing file → turn on the VPN → Enable JIT → the status card shows "JIT active (TXM path)". The log has every `jit:` line.

## 5. Phase 2 — Windows runtime (6.3.0 = CI only, 7.0.0 = first game runs)
### 5.1 CI
Split the work into two workflows. The owner pastes both files on github.com.
- **`build-windows-runtime.yml`** (manual dispatch, `macos-15`, timeout 360 min):
  - Builds the BCD runtime at the pinned tag: Wine native tools, freetype/GnuTLS/FFmpeg for iOS, ntdll-unix, wineserver, win32u-unix, ARM64EC PE modules via llvm-mingw, FEX iOS, DXMT dxgi/d3d11 (+ d3d9 frontend), the D3D12 runtime with Metal Shader Converter, and Wine Mono.
  - Caches each stage keyed by its revision; save each cache in its own step so a later failure keeps finished stages (as BCD does). Use `continue-on-error` only for diagnostic steps.
  - Output: `NexWindows.framework` + `WindowsRuntime.zip` (Windows DLLs, fonts, prefix template). Upload both as a **GitHub release** `windows-runtime-<bcdTag>-<n>`.
- **`build.yml` (app)** gets a dispatch input `windows: true/false` (default true once it works).
  - It downloads the newest `windows-runtime-*` release instead of building it, so app builds stay around 20 minutes.
  - It embeds the framework into `Frameworks/` and the data into `NexPlay.app/WindowsRuntime/`, and sets `NEXPLAY_WINDOWS`.
  - If no release exists, it builds without Windows support and shows a warning.
- Keep the existing Godot/Ren'Py/Ruffle post-build steps.
- **App size will grow by several hundred MB.** Add a `lite` input that skips the Windows runtime for quick UI test builds.

### 5.2 Prefixes (Wine "C: drives")
- Location: `Application Support/NexPlay/Windows/Prefixes/<id>/`. The template is unpacked on first use.
- Default: one shared prefix "Default"; per-game prefixes are optional (Game Settings > Windows > Prefix).
- Saves live inside the prefix (`drive_c/users/<user>/AppData`, `Documents/My Games`, …). The never-lose-a-save rule applies:
  - Back up save folders before a prefix reset or delete.
  - **Save Locations:** a per-game list of known save paths, guessed from file changes after the first session (diff of the prefix's user folders) and editable by the owner. Manage Saves uses it for backup, export and import.
  - Deleting a game rescues its save locations into Rescued Saves.
- Game files stay in `Games/<uuid>/` and are mapped into the prefix as drive `D:` (symlink in `dosdevices`), so games don't get copied into the prefix.

### 5.3 Import
- `UnsupportedEngine.identify` stops rejecting games: anything with an .exe (and no native engine found) becomes a **Windows game**.
- **Main .exe choice:** named like the folder/game; skip `unins*`, `setup*`, `UnityCrashHandler*`, `*redist*`, `vc_redist*`, `dxsetup*`, `notification_helper`. If several remain, ask (exe picker sheet with icons).
- **Engine detection for nicer labels and defaults:**
  - Unity: `UnityPlayer.dll` or `*_Data/`
  - GameMaker: `data.win`
  - WOLF RPG: `Data.wolf` / `Game.exe` + `Data/`
  - KiriKiri: `*.xp3`
  - NScripter / ONScripter: `nscript.dat` / `0.txt`
  - RPG Maker 2000/2003: `RPG_RT.exe` + `RPG_RT.ldb`
  - RPG Maker XP/VX/Ace: `Game.exe` + `Game.rgss*a` / `Data/*.rxdata|rvdata|rvdata2`
  - Godot .NET: `.pck` + `data_*/` with `.dll`
  - XNA: `Microsoft.Xna.Framework*.dll`
  - Ren'Py: `renpy/`
  - NW.js: `nw.dll` + `package.nw`
  - Electron: `resources/app.asar`
- **Installers** (`setup.exe`, GOG `setup_*.exe`, Inno Setup): offer "Run Installer" into the prefix. Then let the owner pick the installed game's .exe from the prefix's `Program Files`. The game entry points into the prefix, not into `Games/`.
- **Godot C#:** the 6.1.1 `RuntimeError.dotNet` banner gets a **Run as Windows Game** button that switches the game to the Windows runtime, as long as its .exe is present. The .exe must be kept at import (check: the extract-embedded-pack step must not delete it).

### 5.4 Running
`WindowsGameRunner`:
1. Ensure JIT (Phase 1).
2. Prepare the prefix.
3. Set the per-game environment.
4. Start wineserver + the game through the runtime's entry point (copy BCD's launch code).
5. Show the game in a Metal-backed view.
6. Feed input.
7. Track playtime and the log.

- **Loading screen with stages:** "Starting Windows", "First-time setup of C: (once)", "Loading game". Show the last log lines (expandable) and a Cancel button.
- **Crash handling:** catch the runtime's exit code and log tail. Show "The game closed" with View Log, Try Recommended Settings and Auto-Tune (BCD's auto-tune: after a crash, change one setting at a time).
- **Background:** pause or suspend the Wine process when NexPlay goes to the background, if BCD supports it. Otherwise warn that iOS may stop it.

### 5.5 Per-game Windows settings (`WindowsGameSettings`, all optional with defaults; source: BCD's per-game page)
- **Graphics:**
  - Resolution or render scale
  - FPS limit (30/40/60/120; 120 suits the 17 Pro Max ProMotion), V-Sync
  - DXMT options BCD exposes
  - D3D12 on/off
  - Performance HUD
- **CPU (FEX):** the TSO/memory-model options, multiblock, x87 reduced precision, SMC checks. Use BCD's names and its defaults per engine.
- **Windows:** Windows version reported, DLL overrides, environment variables, command-line arguments, working directory.
- **Audio:** buffer size.
- **Input:** controller mode (XInput / DirectInput / keyboard+mouse emulation), touch layout, mouse mode (see 7).
- **One-tap Recommended Settings** from BCD's `recommended/` database, matched by exe name/hash, and later from NexPlay's own `tools/windows/recommended.json`.

### 5.6 Runtimes inside Windows
- **Wine Mono** is bundled, for .NET/XNA games.
- **Redistributables** (VC++, DirectX June 2010, XNA 4.0, .NET): Settings > Windows > Components lists them. "Install" asks the owner to import the installer from Files and runs it into the chosen prefix. Nothing from Microsoft is shipped in the app.
- **Fonts:** the Wine fonts plus the CJK fonts BCD ships, if any. Japanese games (RPG Maker 2000, WOLF, KiriKiri) need a Japanese locale option per game (`LANG=ja_JP.UTF-8`) and a Japanese font.

## 6. Phase 3 — Routing every engine (7.1.0)
- **Each game gets a runtime choice:** Automatic / Native / Windows (Game Settings > Engine, and a menu on the Play button).
- **Automatic** means: native if a native runtime exists and isn't known-broken for this game, else Windows.
- **Per engine:**
  - RPG Maker XP/VX/Ace: mkxp when built in, else Windows `Game.exe` (needs the RTP for some games: Components can install the RTP installers the owner imports).
  - RPG Maker 2000/2003: Windows (`RPG_RT.exe`) + Japanese locale option. EasyRPG native stays on the back burner unless Windows fails (see 10).
  - Godot GDScript: web runtime (fast); Godot C#: Windows.
  - Ren'Py: RenPyWeb first; Windows as the fallback for games needing desktop-only Python packages (CLAUDE.md H list).
  - Flash: Ruffle; a Windows projector .exe as the fallback.
  - NW.js/Electron-wrapped HTML games: keep extracting to the web runtime (native is faster); offer Windows as the fallback.
- **Failure suggestions:** when a native run fails (red banner, Godot abort, Ren'Py error), the banner offers **Try with Windows**.

## 7. Phase 4 — Input for PC games (7.2.0)
- **Controllers:** use BCD's controller hub (DualSense/Xbox/Switch Pro/MFi → XInput) for Windows games. The existing GCController code stays for web/Ruby games.
- **Touch controls,** extending NexPlay's `GamepadOverlay` and editor:
  - New `ControlAction`s: mouse left/right/middle, mouse move (trackpad zone), scroll, keyboard keys (all exist for web), XInput buttons/sticks/triggers, Show Keyboard, Quick Save, Quick Load, Game Panel, Fast Forward/Speed.
  - Update every `switch` on `ControlAction`.
  - **Layout presets:** "Controller (Xbox)", "Point & Click", "WASD + Mouse", "Visual Novel", "RPG Maker 2000 (arrows/Z/X/Esc)", "Twin-stick".
  - **Mouse modes:** direct touch = click at the finger; trackpad = relative cursor, tap = click, two-finger tap = right click, two-finger drag = scroll; plus a hold-to-drag option.
  - A soft keyboard with function keys, Esc/Tab/Ctrl/Alt, arrows (this closes the CLAUDE.md C item for every engine).
- **Keyboard/mouse:** pass hardware keyboard and mouse through (UIKit pointer + GCKeyboard/GCMouse) to Wine and to web games.

## 8. Phase 5 — UI/UX overhaul (runs alongside 4–7, and finishes as 7.3.0)
The app grows from "player for RPG Maker" to "game console". Design goals:
- Fast to reach your games.
- Clear what will run and how.
- Setup that guides rather than fails.
- Big touch targets in landscape.

Keep the identity: nebula backgrounds, glass cards, the pixel font, violet accent (`NexStyle`).

### 8.1 Navigation
A bottom tab bar (portrait and landscape):
1. **Home:**
   - Continue (big hero card)
   - Recently Played
   - Favorites
   - Recently Added
   - "Needs Setup" (games blocked by JIT, missing .dll, missing redist)
   - Store shelves when signed in
2. **Library:** the full grid with search, sort and filter chips:
   - Runtime: Native / Windows
   - Engine
   - Status
   - Collections
   - Source: Imported / Steam / GOG
   - Compatibility
3. **Stores** (Phase 6; hidden until enabled).
4. **Settings.**

A floating "+" on Home/Library opens Import with: Files, Folder, Link, Run Installer, Steam, GOG.

### 8.2 Setup Center (first launch of 7.0, and Settings > Setup Center)
A checklist with live status and a fix button per row:
- Pairing file
- LocalDevVPN running
- JIT test passed
- Entitlements present (get-task-allow, memory)
- Windows runtime in this build
- Free storage
- Redistributables installed (optional)

Each row explains in one sentence why it matters. The Home "Needs Setup" shelf links here.

### 8.3 Game cards and game page
- **Card badges:** runtime chip (Native / Windows), engine icon, compatibility dot, "Needs JIT" bolt.
- **Game page** (redesign of `GameDetailView`):
  - Hero art.
  - **Play** button with a runtime chevron (Play Native / Play with Windows).
  - Info chips: playtime, sessions, runtime, size, last played, compatibility.
  - Tabs: **Overview** (notes, developer, status, compatibility vote), **Saves** (save files, save states, save locations for Windows), **Settings** (General, Controls, Engine/Windows, Performance), **Media** (gallery + media browser), **Mods**.
- **Compatibility vote:** Works / Playable / Broken + note. Stored locally. Shown on cards and used by Automatic routing.

### 8.4 In game
- **The control bar's gear opens the Game Panel directly** (closes CLAUDE.md I). The old UIMenu stays reachable with a long-press.
- **Game Panel gains cards for Windows games:** Performance (FPS limit, render scale, HUD toggle), Input (mouse mode, layout preset, show keyboard), Windows (reboot game, kill and restart wineserver, open log).
- **Unified Performance HUD for every runtime:** FPS, frame time graph, CPU %, memory used/available, thermal state (`ProcessInfo.thermalState`), battery. Settings set the corner and detail level.
- Quick Save/Load and Speed can also be control buttons (Phase 4 actions).

### 8.5 JIT sheet
Shown when a game needs JIT and it is off. It has three steps with live ticks: pairing file ✓ / VPN ✓ / Enable JIT [button]. On success it continues straight into the game. It also offers "Use StikDebug instead".

### 8.6 Loading and errors
- One loading screen style for every runtime: game art blurred, stage name, progress ring, expandable log, Cancel.
- Errors become cards with: what happened (plain words), why (log excerpt), what to try (buttons: Try Windows, Recommended Settings, View Log, Copy Log for Claude).

### 8.7 Diagnostics
- Settings > Diagnostics: the app log, game logs (per game, last 5 sessions), the JIT log, device info (model, iOS, TXM, RAM, entitlements, memory limit), the build flags compiled in.
- **Export Logs ZIP** to the share sheet. The owner pastes logs to Claude, so also offer "Copy last 200 lines".

### 8.8 Settings reorganised
Pages:
- General
- Appearance
- Controls & Controllers
- JIT & Performance
- Windows (prefixes, components, defaults, fonts/locale)
- Engines & Runtimes (web/Godot/Ren'Py/Ruffle/mkxp/Windows versions)
- Saves & Backup
- Storage (now lists SaveStates/, prefixes, store downloads)
- Stores
- Privacy
- Setup Center
- Diagnostics
- Credits & Licenses

Keep the search over all rows.

### 8.9 Polish
- Landscape layouts for Home/Library (the 17 Pro Max is wide): 4–6 columns, shelves scroll sideways.
- Haptics on Play, saves and errors.
- Respect Dynamic Type, VoiceOver labels on every control, reduced motion (pause the nebula).
- Light mode stays usable.
- **Empty states with one clear action** for: no games, no Windows runtime in this build, no JIT.
- **What's New 7.0** is a short tour with one slide per feature and a Setup Center button.

## 9. Phase 6 — Stores (7.4.0+, flag `NEXPLAY_STORES`)
- **Steam (from BCD):**
  - Sign-in (password + Steam Guard, or QR), owned library, download/update/verify.
  - Steam Cloud saves.
  - Background downloads on iOS 26 (BCD uses the iOS 26 background task API: copy it).
  - Games that need Steam run through **BCD Dock** (Steam client without its window) inside the game's prefix.
  - Store credentials in the Keychain only. Never log tokens.
- **GOG (from BCD, early):** sign-in, library, download (offline installers or direct files), play without Galaxy.
- **Epic:** not built yet; leave a placeholder only if BCD adds it.
- **Stores tab UI:** account header, library grid with Installed/Not installed, download queue with progress, storage needed vs free.
- Store games appear in Home/Library with a source badge.
- Risk: store logins depend on BCD's code staying current. Pin the version and note in CLAUDE.md how to update it.

## 10. Phase 7 — Extras (as time allows; ordered by value)
1. **Shader/pipeline cache per game** (if DXMT/BCD supports it) for faster second launches.
2. **Save sync** without iCloud: export/import all saves as one ZIP. Optional WebDAV (CLAUDE.md D).
3. **Per-game launch options** (arguments, env) for web games too.
4. **EasyRPG Player native** for RPG Maker 2000/2003 (GPL, CMake). Only if the Windows path is poor for those games. Built in its own CI job like mkxp.
5. **Ruby YJIT for the mkxp core** when JIT is on (if the mkxp-z Ruby version supports arm64 YJIT). Measure first.
6. Home Screen quick actions / widgets for recent games (needs a scene delegate: see the 4.1.0 note).

## 11. Versions and order of pushes
Each step is a separate push that builds and can be tested. Bump the version every push.

| Version | Content | Owner test |
|---|---|---|
| 6.2.0 | Runtime registry refactor (no behaviour change) + entitlements + ldid step + Diagnostics page | Every existing engine still runs; Diagnostics shows get-task-allow |
| 6.3.0 | Built-in JIT + JIT & Performance page + Setup Center (JIT rows) | JIT active on the 17 Pro Max |
| 6.4.0 | `build-windows-runtime.yml` (CI only) + app download step + stub runner | The runtime release appears; the app reports "Windows runtime: present" |
| **7.0.0** | Windows games run: import .exe, prefixes, loading screen, crash card, basic touch mouse + controller | Paper Lily (Windows build), a Unity 2D game, an RPG Maker VX Ace Game.exe |
| 7.1.0 | Routing + engine detection + installers + redistributables + Japanese locale | RPG Maker 2000 game, a Japanese WOLF game |
| 7.2.0 | Input overhaul (presets, mouse modes, soft keyboard, new ControlActions) | Point-and-click and WASD games |
| 7.3.0 | UI overhaul complete (tabs, Home, game page tabs, unified loading/errors/HUD, Settings reorganised, What's New tour) | Whole-app walkthrough |
| 7.4.0+ | Steam, GOG | Sign in, download a small game, play |

Push files that depend on each other in one commit (CLAUDE.md rule). The UI overhaul can ship screen by screen, as long as each push builds.

## 12. Risks and how to handle them
- **Wine/FEX build in CI is long and fragile.** Copy BCD's workflow nearly 1:1, cache every stage, build manually, and keep it separate from the app build.
- **TXM JIT changes with iOS updates.** Keep the StikDebug fallback. Log iOS version + TXM state with every JIT attempt.
- **Memory.** Large games need the increased-memory entitlement. Show available memory in the HUD, and warn before starting games bigger than about 60 % of the memory limit.
- **Storage.** Prefixes + store games are large. The Storage page shows them and can reset or delete prefixes (saves backed up first).
- **One game per process.** If Wine can't restart in-process, say so clearly. Offer "Close NexPlay" when the game ends, and remember the last screen.
- **App size.** Add a `lite` workflow input for UI work.
- **Licensing.** Everything open-source used is credited. Apple's Metal Shader Converter is downloaded in CI only, under Apple's license, and never committed.

## 13. CLAUDE.md updates the build chat must make
- New files and modules, flags, prefix layout, JIT flow, workflow names, the pinned BCD tag and how to bump it.
- New rules:
  - Windows games never write outside their prefix and game folder.
  - Never log store tokens.
  - JIT code paths must work without JIT (fallback messages).
- Move the closed items out of "Not built".

## 14. Open questions for the owner (ask once, then go with the defaults in brackets)
1. **iOS version** on the 17 Pro Max? [read it from the Diagnostics page after 6.2.0]
2. **Signing app:** does it keep entitlements from the binary? Does the certificate allow increased-memory-limit / extended-virtual-addressing? [assume yes; Diagnostics will show it]
3. **Steam/GOG:** wanted in NexPlay even though BCD already does it? [yes, as the last phase]
4. **Workflows:** a separate runtime workflow that the owner runs by hand when the runtime changes? [yes]
5. **Paper Lily:** the full Windows download (exe + `data_*` folder) for the first test? [owner re-imports it]
