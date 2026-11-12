# NexPlay 7.0 Spec — Review v2 (overrides "NexPlay 7.0 Spec" where they differ)

Second pass over the spec, 2026-11-12. The build chat reads both docs, copies them into the repo as `docs/SPEC-7.0.md` and `docs/SPEC-7.0-review.md`, and follows this one where the two differ.

## A. Corrections
1. **Version numbers.** Section 4 says "6.2.0" and section 5 says "6.3.0 = CI only". The **version table in section 11 is the one that counts**: 6.2.0 refactor + entitlements + Diagnostics, 6.3.0 JIT, 6.4.0 runtime CI, 7.0.0 first Windows game.
2. **No processes on iOS.** iOS apps can't `fork`/`exec`. "Start wineserver + the game" (5.4) must follow Madeira/BCD's model, where wineserver and the Windows process run as threads inside NexPlay's own process. Never call `posix_spawn`. Read how BCD does it before designing `WindowsGameRunner`. Expect "one Windows game per app launch" to be true: plan the UI for it from the start (see C4).
3. **FPS default.** The default is **60**, not 120. 120 is opt-in per game. It costs battery and heat for little gain in most games.
4. **Case-sensitive files.** iOS file systems are case-sensitive and Windows games aren't. Wine handles case-insensitive lookups itself, but slowly. Keep BCD's approach, and don't rename game files at import.

## B. Big risks found (check these before building on them)
1. **Graphics APIs: the Windows path only covers some games.**
   - DXMT translates **Direct3D 10/11** to Metal; BCD adds a **Direct3D 9** frontend and a **Direct3D 12** runtime.
   - Games that draw with **OpenGL, Vulkan, DirectDraw / Direct3D 7 and older, or plain GDI** need Wine's wined3d/OpenGL path, which may not exist on iOS.
   - **Check what BCD supports before promising engines:**
     - **Godot 3 desktop builds (Paper Lily) use OpenGL**, so they may not render under BCD.
     - **RPG Maker 2000/2003** use DirectDraw.
     - **RPG Maker XP/VX** use GDI/DirectDraw-style drawing through RGSS; RPG Maker VX Ace (RGSS3) uses Direct3D 9.
     - Many older indie games use OpenGL.
   - Consequences for the plan:
     - Add **graphics API detection at import** (C1), so NexPlay predicts "likely works / unlikely" before you try.
     - **Promote native EasyRPG for RPG Maker 2000/2003** from "extras" to Phase 3 (7.1.0). It is native ARM code: fast, power-efficient, no JIT, and well tested.
     - **mkxp stays the main path for XP/VX/Ace.** Windows Game.exe is only a fallback, and only for RGSS3 (VX Ace).
     - **Paper Lily (Godot 3 C#)** gets a second route if the Windows path can't draw OpenGL: see B2.
2. **Native Godot .NET with JIT (new optional Phase 3b, 7.1.x), only if B1 rules out the Windows path for Godot C#.**
   - Build Godot 3.5.x Mono for iOS in CI, as a `dlopen`ed framework like mkxp. Configure Mono for **JIT** (possible now that NexPlay has JIT) with the interpreter as a fallback.
   - It loads the game's `.pck` plus `data_*/` assemblies directly. It runs natively (GLES3 on iOS), which is better for battery than Wine.
   - Covers every Godot 3 C# game. Godot 4 C# needs a separate look later.
   - Gate it behind the flag `NEXPLAY_GODOT_DOTNET`.
3. **CI layout: everything stays in the NexPlay repo** (the owner confirmed Actions minutes are not a problem).
   - Heavy builds get their own **manual workflows** in `Diam0ndNEX/NexPlay`: `build-windows-runtime.yml`, and later `build-easyrpg.yml` and `build-godot-dotnet.yml`. Each publishes a release in the same repo (`windows-runtime-<tag>-<n>`, …).
   - The normal `build.yml` downloads the newest of each with `gh release download`, so app builds stay fast.
   - The owner pastes every workflow file on github.com.
4. **Metal Shader Converter (needed for the D3D12 runtime).** Apple's download may need an Apple ID login, which is why BCD keeps the installer in a draft release.
   - Plan: the owner downloads it once on the iPhone and attaches the `.pkg` to a draft release named `metal-shader-converter` in the NexPlay repo. CI fetches it from there.
   - If it isn't there, CI builds without D3D12 and logs a warning; D3D9–11 still work.
5. **Release asset size.** GitHub release assets max out at 2 GB each. Split the runtime into `NexWindows.framework.zip` and `WindowsRuntime-data.zip` if needed. The IPA itself will be large (~1 GB), so warn the owner about install time and free space.
6. **The entitlements may not survive signing.** `ldid -S` writes them, but signing apps often take entitlements from the provisioning profile instead. Diagnostics shows the real state.
   - If `get-task-allow` is missing, JIT cannot work. Show a clear message: "Your signing app removed get-task-allow".
   - If the memory entitlements are missing, warn on big games.

## C. Features added in the review
1. **Compatibility prediction at import (PE scan).**
   - Read the main .exe's PE header and import table. Determine 32/64-bit and the graphics API: d3d9 / d3d11 / d3d12 / dxgi / opengl32 / vulkan-1 / ddraw / only gdi32. Detect .NET (CLR header) and Mono/Unity/Godot.
   - Show the result as a badge: "Should work (Direct3D 11)", "Uncertain (OpenGL)", "Unlikely (DirectDraw)". Automatic routing uses it.
   - Store it in `Game.windowsInfo` (optional field).
2. **Game icons from .exe files.** Extract the icon group from the PE resources as a cover candidate (closes CLAUDE.md E "EXE icons"). Unity: `*_Data/Resources/UnityPlayer.png` if present.
3. **Power profiles** (global default + per game; matches the owner's "built-in first for power" goal):
   - **Battery Saver:** 30 FPS cap, render scale 75 %, web games throttled to 30 FPS.
   - **Balanced** (default): 60 FPS.
   - **Performance:** uncapped / 120.
   - **Web games:** the throttle is a `requestAnimationFrame` limiter in the time script (WebTools). A "30 FPS" option for visual novels saves a lot of battery. Add it to the Game Panel.
   - **Windows games:** the FPS limit plus FEX/DXMT settings.
   - **Thermal guard:** when `ProcessInfo.thermalState` reaches `.serious`, show a small toast offering Battery Saver. At `.critical`, auto-pause web games and suggest stopping.
   - **Idle pause:** no input for N minutes (default 10, off for visual novels with auto-advance) pauses the game and dims the screen.
4. **Remember what worked.** When a game first runs fine on a runtime, Automatic remembers it per game (`Game.lastGoodRuntime`). A runtime the owner picks by hand is remembered too.
5. **Per-game "Run Options" for every runtime:** arguments, environment variables, locale. This gives one Settings section instead of a different one per engine.
6. **Bulk import.** Pick a folder of many games; NexPlay finds each game folder (one level down) and imports them in a queue on the existing import card.
7. **Game page notice for C# Godot games:** say before Play is tapped which routes exist (Windows / native .NET, when built in).
8. **Diagnostics self-test** ("Run All Checks"): JIT test, write/read test in Application Support, local server start, each bundled runtime present (Godot, Ren'Py, Ruffle, mkxp, Windows, EasyRPG), free space, memory limit. One-tap copy of the report for Claude.
9. **Crash-safe launch.** If NexPlay crashes while starting a game (e.g. LonaRPG in mkxp), mark that game's runtime "crashed at start" on next launch. Offer another runtime and don't auto-start it again.
10. **Controller-friendly UI.** The whole library (Home/Library/game page) can be driven with a controller (D-pad focus, A = open, Menu = settings). Closes CLAUDE.md D "gamepad navigation of the library".

## D. UI/UX additions
1. **A "How it runs" line on the game page**, in plain words. Examples: "Runs natively in the web runtime — best battery", "Runs through Windows (Wine + FEX) — uses more battery, needs JIT".
2. **Play button states:** Play / Set Up JIT / Missing files / Installing… / Downloading 45 % (stores). Each one taps to the right fix.
3. **Library filter "Ready to play".** Hides games that need setup. "Needs Setup" games get a small amber dot.
4. **One onboarding flow for 7.0:** What's New (3 slides) → Setup Center → done. Skippable, and re-openable from Settings.
5. **In-game Game Panel layout:** keep the cards and add a compact top row of 4 big buttons (Save State, Load, Speed/FPS, Exit) for the most used actions.
6. **Consistent sheets:** every sheet uses the same header (title, close X, optional help ?) and the same glass cards.
7. **Text sizes:** game titles in the pixel font are capped so long titles wrap to 2 lines, never truncated in the middle.

## E. Updated versions table (replaces section 11 rows from 7.1.0 on)
| Version | Content |
|---|---|
| 7.0.0 | Windows games run (D3D9–12 titles) + PE scan badge + exe icons |
| 7.1.0 | Routing, remember-what-worked, engine detection, installers, redistributables, Japanese locale, **EasyRPG native (RPG Maker 2000/2003)** |
| 7.1.x | Optional: native Godot .NET with JIT, only if Windows can't draw Godot 3 games |
| 7.2.0 | Input overhaul + power profiles + idle pause + thermal guard |
| 7.3.0 | UI overhaul complete + controller-driven library + onboarding + Diagnostics self-test + bulk import |
| 7.4.0+ | Steam, GOG |

## F. Questions to ask the owner once (defaults in brackets)
1. iOS version on the 17 Pro Max? [read from Diagnostics]
2. Does the signing app keep binary entitlements? Is increased-memory allowed? [Diagnostics shows it]
3. Steam/GOG in NexPlay? [yes, last]
4. Re-import Paper Lily with its .exe and `data_*` folder? [yes]
