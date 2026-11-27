(* Which hints of a compiled CairoZero program this VM implements.
   usage: hint_coverage.exe program.json [--unknown]
   Prints "known/distinct" and one line per distinct hint code: K (native)
   or U (unknown), the number of sites, and the code's first line. *)
let () =
  let file = Sys.argv.(1) and only_unknown = Array.mem "--unknown" Sys.argv in
  Cairovm.Hints_registry.init ();
  let prog = Cairovm.Program.load_file file in
  let sites = Hashtbl.create 256 in
  List.iter
    (fun (_, hs) ->
      List.iter
        (fun (h : Cairovm.Program.hint) ->
          Hashtbl.replace sites h.code (1 + Option.value ~default:0 (Hashtbl.find_opt sites h.code)))
        hs)
    prog.hints;
  let codes = List.sort compare (Hashtbl.fold (fun c n acc -> (c, n) :: acc) sites []) in
  let known c = Hashtbl.mem Cairovm.Hints.table c in
  Printf.printf "%d/%d distinct hint codes implemented (%d sites)\n"
    (List.length (List.filter (fun (c, _) -> known c) codes))
    (List.length codes)
    (List.fold_left (fun a (_, n) -> a + n) 0 codes);
  List.iter
    (fun (c, n) ->
      if not (only_unknown && known c) then
        Printf.printf "%s %3d %s\n" (if known c then "K" else "U") n (List.hd (String.split_on_char '\n' c)))
    codes
