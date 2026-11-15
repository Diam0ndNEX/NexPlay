# NexShim (8.10.0)

Godot 3.5.3 Mono's web runtime has no threads and its thread pool runs only the first work item, so C# games that
use `Task.Run` more than once, or wait with `Monitor.Wait` inside a task (Project Kat / Paper Lily's Lacie Engine),
stall. `mscorlib.dll` here is the runtime's own, with `Task.Run(...)` and `Monitor.Wait(...)` redirected (Mono.Cecil,
`Patch.cs`) to `NexShim.dll` (`NexShim.cs`): work items run on the main thread, one batch per frame, and a wait loop
re-runs once per frame. The build copies both over `GodotRuntimes/godotmono-3.5.3/assemblies/`.
Rebuild: `mcs -target:library -out:NexShim.dll -r:GodotSharp.dll -r:netstandard.dll NexShim.cs`, then
`mono Patch.exe <original mscorlib.dll> NexShim.dll mscorlib.dll`.
