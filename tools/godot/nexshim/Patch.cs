using System; using System.Linq; using Mono.Cecil; using Mono.Cecil.Cil;
class P { static int Main(string[] a) {
  var mscor = AssemblyDefinition.ReadAssembly(a[0], new ReaderParameters{ReadWrite=false});
  var shim = AssemblyDefinition.ReadAssembly(a[1]);
  var nex = shim.MainModule.GetType("NexPlayShim.Nex");
  var m = mscor.MainModule;
  m.AssemblyReferences.Add(shim.Name);
  int n=0;
  var task = m.GetType("System.Threading.Tasks.Task");
  foreach (var md in task.Methods.Where(x=>(x.Name=="Run"||x.Name=="Delay") && x.IsStatic && x.IsPublic && x.Parameters.Count>=1).ToList()) {
    MethodDefinition target = null;
    foreach (var s in nex.Methods.Where(x=>x.Name==md.Name && x.Parameters.Count==md.Parameters.Count && x.HasGenericParameters==md.HasGenericParameters)) {
      bool same = Sig(md.ReturnType)==Sig(s.ReturnType);
      for (int k=0;k<md.Parameters.Count;k++) if (Sig(md.Parameters[k].ParameterType)!=Sig(s.Parameters[k].ParameterType)) same=false;
      if (same) target=s;
    }
    if (target==null) { Console.WriteLine("skip "+md); continue; }
    var il = md.Body.GetILProcessor(); md.Body.Instructions.Clear(); md.Body.ExceptionHandlers.Clear(); md.Body.Variables.Clear();
    for (int k=0;k<md.Parameters.Count;k++) il.Emit(OpCodes.Ldarg, md.Parameters[k]);
    MethodReference mr = m.ImportReference(target);
    if (md.HasGenericParameters) { var g = new GenericInstanceMethod(mr); g.GenericArguments.Add(md.GenericParameters[0]); mr = g; }
    il.Emit(OpCodes.Call, mr); il.Emit(OpCodes.Ret); n++;
    Console.WriteLine("patched "+md);
  }
  var mon = m.GetType("System.Threading.Monitor");
  var wait = nex.Methods.First(x=>x.Name=="Wait");
  foreach (var md in mon.Methods.Where(x=>x.Name=="Wait" && x.IsStatic && x.IsPublic && x.HasBody)) {
    var il = md.Body.GetILProcessor(); md.Body.Instructions.Clear(); md.Body.ExceptionHandlers.Clear(); md.Body.Variables.Clear();
    il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Call, m.ImportReference(wait)); il.Emit(OpCodes.Ret); n++;
    Console.WriteLine("patched "+md);
  }
  mscor.Write(a[2]); Console.WriteLine("done "+n); return 0; }
  static string Sig(TypeReference t){ return t.FullName.Replace("!!0","T").Replace("`1","").Replace("System.Threading.Tasks.Task<TResult>","Task<T>").Replace("System.Threading.Tasks.Task<T>","Task<T>").Replace("TResult","T"); }
}
