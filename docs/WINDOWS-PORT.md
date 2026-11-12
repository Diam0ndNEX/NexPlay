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

## Port plan
1. **6.4.0 (CI only)** `docs/workflow-windows-runtime.yml` → owner pastes as `.github/workflows/build-windows-runtime.yml`
   (manual dispatch, macos runner, long timeout): download `BCD-source.tar.xz` for the tag in `tools/windows/runtime.version`,
   run BCD's stage scripts in BCD's order (copy the stage steps of build-ipa.yml nearly 1:1, drop Steam/Dock/EA/itch stages,
   cache each stage by revision, save each cache in its own step), skip the BCD app archive. Package
   `NexWindowsLibs.zip` (every static lib the BCD app links) + `WindowsRuntime.zip` (DLL folders, nls, prefix template,
   soundfont, cacert) and publish them as release `windows-runtime-<tag>-<n>` in Diam0ndNEX/NexPlay. Metal Shader Converter:
   from a draft release `metal-shader-converter` the owner fills once; without it D3D12 is skipped with a warning.
   App side: `build.yml` downloads the newest runtime release (`gh release download`), puts the data in
   `NexPlay.app/WindowsRuntime/`; `WindowsGameRuntime` stub reports "Windows runtime: present" in Diagnostics.
2. **7.0.0** copy BCD's glue (list above, minus Steam/stores) into `NexPlay/Windows/BCD/` with headers kept, compiled only with
   `NEXPLAY_WINDOWS` (link the runtime libs then). Replace the 6.3.0 JIT self-test with BCD's pool request and keep the
   debugger attached for the session (JIT script already is BCD's). `WindowsGameRunner`: ensure JIT, seed prefix
   (`Application Support/NexPlay/Windows/Prefixes/<id>`), mount the game folder as D:, `wine_process_start`, Metal view from
   Winios, input bridge, exit/crash card. One Windows game per app launch.
3. 7.1+ as in SPEC-7.0 + review (routing, EasyRPG native, input, power, UI).

Do not start by rewriting: copy BCD's files and stage steps as they are, then cut what NexPlay doesn't use.
