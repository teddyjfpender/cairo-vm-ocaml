(* Extra hint modules register here.  Each line forces its module to be linked
   (OCaml drops unreferenced library modules) and adds its hints to
   Hints.table.  Add one line per module: `Hints_xyz.register ();` *)
let initialized = ref false

let init () =
  if not !initialized then begin
    initialized := true;
    Hints_secp.register ();
    Hints_misc.register ();
    Hints_builtins.register ();
    ()
  end
