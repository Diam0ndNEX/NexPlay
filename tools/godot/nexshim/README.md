# NexShim (8.10.0)

Godot 3.5.3 Mono's web runtime has no threads and its thread pool runs only the first work item, so C# games that
use `Task.Run` more than once, or wait with `Monitor.Wait` inside a task (Project Kat / Paper Lily's Lacie Engine),
stall. `mscorlib.dll` here is the runtime's own, with `Task.Run(...)`, `Task.Delay(...)` and `Monitor.Wait(...)` redirected (Mono.Cecil,
`Patch.cs`) to `NexShim.dll` (`NexShim.cs`): work items run on the main thread, one batch per frame, and a wait loop
re-runs once per frame. The build copies both over `GodotRuntimes/godotmono-3.5.3/assemblies/`.
Rebuild: `mcs -target:library -out:NexShim.dll -r:GodotSharp.dll -r:netstandard.dll NexShim.cs`, then
`mono Patch.exe <original mscorlib.dll> NexShim.dll mscorlib.dll`.

8.10.3: Task.Delay too. Mono's timer fires from its own callback in the ROOT app domain, whose statics are empty, so the game's code after `await Task.Delay` (Lacie: DrkieUtil.DelaySeconds) ran with Game.Settings == null (NRE every frame in StoryPlayer after New Game). NexShim runs delays from the main loop instead.

8.10.4: one patched mscorlib per C# runtime version (mscorlib-3.5.3.dll, mscorlib-3.6.3.dll); a new Mono runtime needs `mono Patch.exe <its mscorlib.dll> NexShim.dll mscorlib-<v>.dll`. 3.6.3 checked with Kat's pack (same flow as 3.5.3).
