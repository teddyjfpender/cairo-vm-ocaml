(* CLI compatible with cairo-vm-cli (non-proof mode subset). *)
open Cairovm

let () =
  let file = ref None and trace = ref None and memory = ref None in
  let layout = ref "plain" and print_output = ref false and entry = ref "main" in
  let secure = ref None and allow_missing = ref false and stats = ref false in
  let bool_of s = match s with "true" -> true | "false" -> false | _ -> raise (Arg.Bad ("expected true|false: " ^ s)) in
  let spec =
    [
      ("--trace_file", Arg.String (fun s -> trace := Some s), "FILE  write the relocated binary trace");
      ("--memory_file", Arg.String (fun s -> memory := Some s), "FILE  write the relocated binary memory");
      ("--layout", Arg.Set_string layout, "LAYOUT  builtin layout (default plain)");
      ("--print_output", Arg.Set print_output, " print the output builtin segment");
      ("--entrypoint", Arg.Set_string entry, "NAME  entrypoint (default main)");
      ("--secure_run", Arg.String (fun s -> secure := Some (bool_of s)), "true|false");
      ("--allow_missing_builtins", Arg.String (fun s -> allow_missing := bool_of s), "true|false");
      ("--proof_mode", Arg.Unit (fun () -> prerr_endline "error: --proof_mode is not supported"; exit 2), " (unsupported)");
      ("--stats", Arg.Set stats, " print step count and timing to stderr");
    ]
  in
  Arg.parse spec (fun f -> file := Some f) "cairo-vm-ocaml PROGRAM.json [options]";
  let file = match !file with Some f -> f | None -> prerr_endline "missing program file"; exit 2 in
  try
    let t0 = Unix.gettimeofday () in
    let prog = Program.load_file file in
    let cfg =
      {
        Runner.layout = !layout;
        trace = !trace <> None;
        secure_run = Option.value !secure ~default:true;
        allow_missing_builtins = !allow_missing;
        entrypoint = !entry;
      }
    in
    let r = Runner.initialize cfg prog in
    let t1 = Unix.gettimeofday () in
    Runner.run_until_end r;
    let t2 = Unix.gettimeofday () in
    Runner.end_run r ~secure:cfg.secure_run ~allow_missing:cfg.allow_missing_builtins;
    if !print_output then begin
      print_string "Program Output:\n";
      Runner.iter_output_lines r (fun line -> output_string stdout line; output_char stdout '\n');
      flush stdout
    end;
    Option.iter (Runner.write_trace r) !trace;
    Option.iter (Runner.write_memory r) !memory;
    if !stats then
      Printf.eprintf "generic=%d hint_pcs=%d " !Vm.generic_steps !Vm.hint_steps;
    if !stats then
      Printf.eprintf "steps=%d load=%.3fs run=%.3fs (%.1f Msteps/s) total=%.3fs\n" r.vm.steps (t1 -. t0) (t2 -. t1)
        (float r.vm.steps /. (t2 -. t1) /. 1e6) (Unix.gettimeofday () -. t0)
  with
  | Vm.Vm_error msg ->
      prerr_endline ("Error: " ^ msg);
      exit 1
  | Program.Parse_error msg ->
      prerr_endline ("Error: " ^ msg);
      exit 1
