// NexShim: Godot 3 Mono's web runtime has no threads and its thread pool runs only the first work item.
// mscorlib's Task.Run / Monitor.Wait are patched (offline, with Cecil) to call these instead:
// work items run on the main thread, one batch per frame; a Monitor.Wait inside one throws NexWouldBlock and the item is
// run again on the next frame (a wait loop re-checks its condition once per frame).
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace NexPlayShim {
    public sealed class NexWouldBlock : Exception { public NexWouldBlock() : base("would block") { } }

    public sealed class PumpNode : Node {
        public override void _Process(float delta) { Nex.Pump(); }
    }

    public static class Nex {
        static readonly List<Action> queue = new List<Action>();
        static PumpNode node;
        static bool installing;

        static void Install() {
            if (node != null && Godot.Object.IsInstanceValid(node)) return;
            if (installing) return;
            installing = true;
            try {
                var tree = Engine.GetMainLoop() as SceneTree;
                if (tree == null || tree.Root == null) return;
                node = new PumpNode();
                node.Name = "NexPump";
                node.PauseMode = Node.PauseModeEnum.Process;
                tree.Root.CallDeferred("add_child", node);
            } finally { installing = false; }
        }

        static void Enqueue(Action a) {
            lock (queue) queue.Add(a);
            Install();
        }

        public static void Pump() {
            Action[] batch;
            lock (queue) { if (queue.Count == 0) return; batch = queue.ToArray(); queue.Clear(); }
            foreach (var a in batch) a();
        }

        static void Step(Action work, Action<Exception> fail, Action done) {
            Enqueue(() => {
                try { work(); }
                catch (NexWouldBlock) { Step(work, fail, done); return; }
                catch (Exception e) { fail(e); return; }
                done();
            });
        }

        public static Task Run(Action action) {
            var tcs = new TaskCompletionSource<bool>();
            Step(action, e => tcs.SetException(e), () => tcs.SetResult(true));
            return tcs.Task;
        }

        public static Task<T> Run<T>(Func<T> func) {
            var tcs = new TaskCompletionSource<T>();
            T result = default(T);
            Step(() => { result = func(); }, e => tcs.SetException(e), () => tcs.SetResult(result));
            return tcs.Task;
        }

        public static Task Run(Func<Task> func) {
            var tcs = new TaskCompletionSource<bool>();
            Task inner = null;
            Step(() => { inner = func(); }, e => tcs.SetException(e), () => {
                if (inner == null) { tcs.SetResult(true); return; }
                inner.GetAwaiter().OnCompleted(() => {
                    if (inner.IsFaulted) tcs.SetException(inner.Exception.InnerExceptions); else if (inner.IsCanceled) tcs.SetCanceled(); else tcs.SetResult(true);
                });
            });
            return tcs.Task;
        }

        public static Task<T> Run<T>(Func<Task<T>> func) {
            var tcs = new TaskCompletionSource<T>();
            Task<T> inner = null;
            Step(() => { inner = func(); }, e => tcs.SetException(e), () => {
                if (inner == null) { tcs.SetResult(default(T)); return; }
                inner.GetAwaiter().OnCompleted(() => {
                    if (inner.IsFaulted) tcs.SetException(inner.Exception.InnerExceptions); else if (inner.IsCanceled) tcs.SetCanceled(); else tcs.SetResult(inner.Result);
                });
            });
            return tcs.Task;
        }

        // Monitor.Wait(object): never blocks; the work item is run again next frame.
        public static bool Wait(object o) { throw new NexWouldBlock(); }
    }
}
