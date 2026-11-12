# Owner answers to the 7.0 questions (2026-11-12)

These override `SPEC-7.0.md` and `SPEC-7.0-review.md` where they differ.

1. **iOS version:** iOS 27 or later on the iPhone 17 Pro Max. TXM device: JIT needs the TXM path.
2. **Certificate:** a development certificate. Its profile grants `get-task-allow`,
   `com.apple.developer.kernel.increased-memory-limit`, `com.apple.developer.kernel.increased-debugging-memory-limit`,
   `com.apple.developer.kernel.extended-virtual-addressing`, and `com.apple.developer.networking.networkextension`
   (including `packet-tunnel-provider`). NexPlay.entitlements asks for the first four since 6.2.1.
   The network-extension grant means NexPlay could ship its own tunnel (like LocalDevVPN) later, so JIT
   wouldn't need a second app. Not planned yet; decide during 6.3.0.
3. **Steam/GOG: dropped.** No Stores phase (no 7.4.0, no `NEXPLAY_STORES`, no Stores tab, no store sources in
   filters or Import). `GameSource` stays as a field (always `imported`).
4. **Paper Lily:** the owner re-imports the full Windows download (.exe + `data_*`) for the first Windows test.
