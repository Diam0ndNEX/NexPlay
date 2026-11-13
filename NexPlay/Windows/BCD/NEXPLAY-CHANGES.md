# BCD's app code in NexPlay: origin and changes

This folder holds the app code of BCD (https://github.com/thebcd69/bcd-games, tag **v0.1.653**, commit
c3c2d152fca4d491b703b910d112ab54299c36c1), from `app/Madeira`: every file of its Madeira target's Sources phase
(340 files) and the headers next to them. BCD is a fork of Madeira by Will Faust (https://github.com/willfaust/Madeira).
Every file keeps its own header and licence (GPL-3.0-only with BCD's additional terms, GPL-3.0-or-later from Madeira,
the Madeira Converter Exception). The licence files are in `third_party/bcd/` at the top of the repository.

Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)

This is a modified version of BCD and not the official BCD. NexPlay is a private app that compiles this code
into its own target (only in builds with the Windows engine, see `NexPlayWindows.yml` and `docs/WINDOWS-PORT.md`).

## Changes (GPL-3.0 section 5(a), BCD additional terms 4(c)2)

### 2026-11-13, NexPlay 8.0.0 (core merge)
- Not copied: `MadeiraApp.swift` (BCD's `@main` app; its init and WindowGroup are in `NexPlayBCDHost.swift`),
  `Info.plist`, the entitlements, `Assets.xcassets` (BCD's icon and logo), the Windows DLL folders, the static
  libraries and the other resources (they come from NexPlay's engine build: `tools/windows/package_engine.sh`).
- Added: `NexPlayBCDHost.swift` (NexPlay's code: engine start, library entries for NexPlay's games, the session
  screen NexPlay embeds, NexPlay's JIT), `build-headers/` (copies of BCD's `build/madeira_cfg.h`,
  `build/madeira_redact.h`, `build/bcd_epic_mask.h`), `recommendations.json` (from BCD's `recommended/`).
- `JITAllocator.c`, `WineProcessBridge.m`: the `../../build/*.h` includes point at `build-headers/`.
- Renamed BCD types whose names NexPlay already uses (both live in one Swift module now), in every file that names
  them: `ControlAction` → `BCDControlAction`, `CoverStore` → `BCDCoverStore`, `LibraryController` →
  `BCDLibraryController`, `LocalDevVPN` → `BCDLocalDevVPN`, `LoopbackProbe` → `BCDLoopbackProbe`,
  `OnboardingView` → `BCDOnboardingView`.
- `ContentView.swift`: no BCD front end (`BCDLiveFrontEnd` is replaced by `NexWindowsIdleView`; NexPlay's library
  starts games); Enable JIT uses NexPlay's JIT (`NexWindowsHost.enableJIT`, NexPlay's helper and pairing file) instead
  of BCD's JIT coordinator; BCD's JIT setup sheet is not shown; the restart alert names NexPlay.
- `Library.swift`: the one-game-per-run message names NexPlay.

### 2026-11-13, NexPlay 8.2.0 (Controls Style)
- Added: `NexPlayPCControls.swift` (NexPlay's code, not BCD's): BCD's touch layer and editor over NexPlay's web-view
  games, and NexPlay's pad over Windows games. No BCD file was changed.

### 2026-11-13, NexPlay 8.2.1 (layout presets)
- `NexPlayPCControls.swift` (NexPlay's code) gains `NexPCPresets`: NexPlay's layout presets written as BCD touch
  layouts. No BCD file was changed.
