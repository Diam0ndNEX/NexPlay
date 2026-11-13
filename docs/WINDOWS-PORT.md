# Windows engine: what BCD is made of and how NexPlay takes it

## 8.0.0: BCD merged into NexPlay (current)
BCD's app code is NexPlay source; only the engine is prebuilt. Supersedes the 6.4.0 "BCD as a library" plan below.

**Source.** `NexPlay/Windows/BCD/` = BCD v0.1.653 `app/Madeira`: the 340 files of its Madeira target's Sources phase
(313 Swift, the C/ObjC/C++ glue: WineProcessBridge.m, WineServerBridge.m, FEXBridge.mm, JITAllocator.c,
IOSDisplayShim.m, Winios/, PadOutput.m, MemoryPool.m, ...) + headers + `Madeira-Bridging-Header.h`,
`madeira-exports.txt`, `BCDThemes.json`, `recommendations.json`, `build-headers/` (BCD's build/*.h the glue includes).
Not copied: MadeiraApp.swift (@main), Info.plist, entitlements, Assets (BCD icon/logo), the extensions
(MadeiraJITHelper: NexPlay's JIT replaces it; MadeiraMemoryHost: opt-in helper memory, not built). Every change is
listed in `NexPlay/Windows/BCD/NEXPLAY-CHANGES.md`; BCD's licence files are in `third_party/bcd/`.

**Build switch.** `project.yml` includes `NexPlayWindows.yml`. Committed = OFF (BCD folder excluded, NexPlay's
bridging header). In CI `tools/windows/fetch_engine.sh` (build.yml, before xcodegen) downloads the newest
`windows-engine-*` release into `vendor/bcd-engine` and copies `tools/windows/NexPlayWindows-on.yml` over it: the BCD
folder becomes a source, `NexPlay/Windows/NexPlayWindows-Bridging-Header.h` (NexPlay's + BCD's), BCD's libraries and
frameworks, FEX header paths, `EXPORTED_SYMBOLS_FILE`, gnu++20, and BCD's Debug flavour (-Onone/-O0, DEBUG=1;
"Release builds have crashed the guest", BCD's docs/BUILDING.md). Swift sees `NEXPLAY_WINDOWS`
(`OTHER_SWIFT_FLAGS`). After the build `tools/ci/package_extras.sh` → `tools/windows/merge_engine.sh` copies the
engine resources into NexPlay.app, signs the loose dylibs (d3d12/, gl/) with ldid and fails the build when NexPlay's
binary doesn't export the six macdrv symbols DXMT looks up.

**Engine build** (`docs/workflow-windows-runtime.yml` → build-windows-runtime.yml, manual, same jobs/caches as
7.13.2): `tools/windows/build_engine.sh` (Metal Shader Converter from third_party, ccache, `run_bcd_ci.py --until
"Archive (unsigned)"` = all of BCD's build steps before its app archive) → `package_engine.sh` → BCDEngine.zip:
`lib/` (libntdll_unix, libwin32u_unix, libwineserver, libdxmt_combined, libmadeira_rppairing, GnuTLS stack, FFmpeg,
FEX's seven archives), `fex/` (FEX header tree), `resources/` (nls, aarch64-/arm64ec-/i386-windows, x86_64-vcruntime,
compat, gl, vulkan, d3d12, legal, licenses, soundfont, prefix-template.tar.gz, cacert.pem, wine-mono), `ENGINE.txt`
→ `publish_engine.sh` (release `windows-engine-<tag>-<run>`, split above 1.9 GB).

**Run time.** WindowsGameRuntime → `WindowsLaunchController` (NexPlay's loading screen over a child
`NexWindowsSession.controller` = BCD's ContentView session path). Start: C:\NexPlay\<id> symlink → BCD library entry
(`NexWindowsHost.addGame`) → `ShortcutRouter` with C:\NexPlay\<id>\<program> → ContentView.launchLibraryEntry (BCD's
checks, JIT pool, Wine). JIT: NexPlay's JITManager only; with the engine built in it keeps the debugger attached
(BCD's pool requests need it). Session events (LibraryModel current/error/startingJIT) drive the loading screen, the
error card and the return to the library. One Wine session per app run (BCD's restart alert). BCD's engine services
(controllers, keyboard/mouse, background run, external drives) start at the first Windows game
(`NexWindowsHost.startOnce`).

**Still BCD's (until later 8.x steps):** in-game menu/HUD/touch controls (8.2/8.3), the game's settings (8.4), store,
Dock and BCD front-end code compiled but unreachable (removed in 8.5/8.7).

# History: Windows runtime port (6.4.0 → 7.0.0)

Owner decision (2026-11-12): **full port into NexPlay** (not a hand-off to BCD, not skipped). Expect many build-fix rounds.
The owner tests on the device only after the whole update; build errors still come first (fix the first error first).

## What BCD's Windows support is (read 2026-11-12, BCD v0.1.653)
- Releases (github.com/thebcd69/bcd-games/releases): each has `BCD.ipa` (unsigned, iOS 18+, needs JIT) and
  `BCD-source.tar.xz` (complete source with every submodule: Wine, FEX, DXMT, madeira-dock). Pin a tag; v0.1.653 is current.
- `.github/workflows/build-ipa.yml` is ~324 KB (not 2,669 lines as the spec said). It drives the stage scripts in `build/`:
  `wineserver`, `ntdll-unix` (huge iOS ports: virtual_ios.c 2.2 MB, signal_arm64_ios.c 1.1 MB, server_ios.c, process_ios.c,
  thread_ios.c, loader_ios.c, env_ios.c, audio/MIDI/gstreamer shims; `build.sh` per stage), `win32u-unix`, `wineios-drv`,
  `wine-pe`, `wine-i386`, `wine-mono`, `fex-ios`, `fex-arm64ec`, `fex-wow64`, `dxmt-ios`, `madeira-d3d12` (needs Apple's
  Metal Shader Converter), `mesa-ios`, `moltenvk-ios`, `freetype-ios`, `gnutls-ios`, `crypto-unix`, `ffmpeg`, `luajit-x64`,
  `rppairing-ios`, `madeira-dock`/`bcd-host` (Steam: not needed, stores dropped), `madsync`, `hidpad`, `faultrep`, `tftrace`.
  Shared headers: `build/madeira_cfg.h` (bcd.cfg reader), `build/madeira_redact.h`.
- Prebuilt pieces committed in `app/Madeira`: `libgmp.a`, `libgnutls.a`, `libhogweed.a`, `libnettle.a`, `app/libdxmt_unix.a`,
  Windows DLL folders `aarch64-windows/`, `arm64ec-windows/`, `i386-windows/`, `x86_64-vcruntime/`, `d3d12/`, `nls/`,
  `prefix-template.tar.gz`, `soundfont/`, `cacert.pem`.
- The glue is compiled into BCD's own app target (not a library): `WineProcessBridge.m` (260 KB: `wine_process_start(prefix)`,
  session end, exit status, stdin/stdout pipes, `madeira_seed_prefix_if_needed`), `WineServerBridge.m`, `FEXBridge.mm`,
  `JITAllocator.c` (pool, early VA claim constructor at 0x140000000, BRK protocol), `IOSDisplayShim.m`, `Winios/` (display,
  cursor, Metal background gate, CPU cap), `PadOutput.m`, `PrefixExtractor.c`, `BCDCab.c`, `BCDFrameRing.c`, `BCDPauseGate.c`,
  `MemoryPool.m` + the `MadeiraMemoryHost` extension (helper memory). C API list: `app/Madeira/Madeira-Bridging-Header.h`.
- Swift side that drives a session: `StikJITHelper.swift` (160 KB: pool request `allocatePool`, keeps the debugger attached while
  Wine runs), `Library.swift` / `BCDSessionLive.swift` / `ContentView.swift` (launch, environment, bcd.cfg per game),
  `HardwareInput.swift` + `GamepadInput.swift` (input), `GameRecommendations*` + `AutoTune*` (per-game settings).
- Licences: BCD files GPL-3.0-only with BCD additional terms (LICENSE-BCD.md: Credits line required, no BCD name/icon);
  Madeira parts GPL-3.0-or-later + Madeira Converter Exception; Wine LGPL; FEX MIT; DXMT zlib/MIT. NexPlay stays private.

## Port plan (changed 6.4.0: BCD as a library, not copied glue)
BCD's glue is compiled into its app target and DXMT finds `macdrv_*` by `dlsym(RTLD_DEFAULT)` from that target's export
list, so copying single files would mean re-creating BCD's whole app. Instead NexPlay builds BCD's app target as a
dynamic library and loads it.

1. **6.4.0 (done, untested)** `docs/workflow-windows-runtime.yml` → `.github/workflows/build-windows-runtime.yml` (manual,
   macos-15, 6 h). Checks out BCD at `tools/windows/runtime.version` with submodules into `bcd/`, then
   `tools/windows/build_runtime.sh`:
   - `run_bcd_ci.py` replays BCD's own `.github/workflows/build-ipa.yml` step by step (evaluates `${{ }}` and `if:`,
     GITHUB_ENV/PATH/OUTPUT, BCD's cache steps against `bcd/.nexplay-cache`, skips other `uses:` and BCD's host tests)
     until "Archive (unsigned)". Our own cache step keeps BCD's build folders between runs.
   - `patch_bcd_for_nexplay.py`: Madeira target links as MH_DYLIB (`@rpath/BCDCore.framework/BCDCore`); appends to
     MadeiraApp.swift `nexplay_bcd_make_root()` (BCD's init body once + a retained UIHostingController of its WindowGroup
     content) and `nexplay_bcd_open_url(const char*)` (its onOpenURL body); adds both to madeira-exports.txt.
   - xcodebuild archive (Debug, as BCD does), BCD's macdrv export check, `package_runtime.sh` → `BCDRuntime.zip`
     (Frameworks/BCDCore.framework + BCD's other frameworks minus StikJIT, AppResources/ = BCD's app folder contents,
     PlugIns/ renamed to com.nexplay.app.BCD<Name>, BCD-Info.plist whitelist), split above 1.9 GB.
   - `publish_runtime.sh` → release `windows-runtime-<tag>-<run>`.
   `build.yml` (`docs/workflow-6.4.0.yml`) runs `merge_runtime.sh` on the unsigned app: newest runtime release, resources
   merged with NexPlay's files winning, frameworks and plug-ins added, Info.plist keys merged, `WindowsRuntime.version`.
   App: `NexPlay/Windows/BCDBridge.swift` (`BCDRuntimeInfo` dlopen + launch crash guard, `BCDBridge.show/open`,
   `WindowsHostViewController`), Setup Center > Windows Games (Open Windows Games, Load at Launch), remote pairing file
   mirrored to BCD's Keychain item (MadeiraJITPairing/rppairing).
2. **7.0.0 (done, untested)** Windows games in NexPlay's library. Files stay in NexPlay's Games/<id>; a symlink
   C:\NexPlay\<id> on BCD's drive points at them; `nexplay_bcd_add_game` makes the BCD library entry (BCD only starts
   play links for games in its library); `madeira://play?exe=C:\NexPlay\<id>\<program>` starts it with BCD's own JIT
   and launch sequence. Closing BCD's screen returns to NexPlay's library. BCD's per-game settings stay on BCD's page.
3. 7.1+ as in SPEC-7.0 + review (routing, EasyRPG native, input, power, UI).

Known risks to check on the first runtime build: BCD's code using `Bundle.main` paths (covered by merging its app folder
into NexPlay.app), Assets.car (NexPlay's kept), Info.plist keys BCD reads, BCD plug-in ids, release asset size (2 GB).

## Metal Shader Converter (7.1.5)
BCD's public repo (tag v0.1.653) does not contain `app/Madeira/d3d12/libmetalirconverter.dylib`, so its `deps.sh` stopped the runtime build after ~70 minutes. NexPlay now keeps the iOS dylib and headers of Metal Shader Converter 4.0 beta 3 in `third_party/metal-shader-converter/` (see its README). `tools/windows/build_runtime.sh` copies them into BCD's tree, rewrites BCD's header SHA256SUMS and re-pins the dylib hash in BCD's deps.sh/fetch-converter.sh (BCD pins beta 2). No release or manual step.
