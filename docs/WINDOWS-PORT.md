# Windows runtime port (6.4.0 → 7.0.0): what BCD is made of and how NexPlay takes it

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
