(* CLI compatible with cairo-vm-cli (non-proof mode subset). *)
open Cairovm

(* An explicitly configured Rust executable covers modes outside the native
   runner. execv preserves the original argument vector and exit status. *)
let rust = Sys.getenv_opt "CAIRO_VM_RUST_CLI"

let delegate message =
  match rust with
  | None -> prerr_endline ("error: " ^ message); exit 2
  | Some path ->
      (try
         if Sys.getenv_opt "CAIRO_VM_DELEGATED" = Some "1" then failwith "recursive Cairo VM fallback";
         let current = Unix.stat Sys.executable_name and target = Unix.stat path in
         if current.st_dev = target.st_dev && current.st_ino = target.st_ino then
           failwith "CAIRO_VM_RUST_CLI points to this executable";
         Unix.putenv "CAIRO_VM_DELEGATED" "1";
         let argv = Array.copy Sys.argv in
         argv.(0) <- path;
         Unix.execv path argv
       with Failure msg -> prerr_endline msg; exit 2
          | Unix.Unix_error (e, _, _) -> prerr_endline (path ^ ": " ^ Unix.error_message e); exit 2)

let () =
  let file = ref None and trace = ref None and memory = ref None in
  let layout = ref "plain" and print_output = ref false and entry = ref "main" in
  let secure = ref None and allow_missing = ref None and stats = ref false in
  let fill_holes = ref None and proof = ref false and merge_extra = ref false in
  let air_public = ref None and air_private = ref None and pie_out = ref None and layout_params = ref None in
  let positional f = match !file with
    | None -> file := Some f | Some _ -> raise (Arg.Bad "expected one program file") in
  let version () = if rust <> None then delegate "version"; print_endline "cairo-vm-cli 3.2.0 (OCaml)"; exit 0 in
  let bool_of s = match s with "true" -> true | "false" -> false | _ -> raise (Arg.Bad ("expected true|false: " ^ s)) in
  let spec =
    [
      ("--trace_file", Arg.String (fun s -> trace := Some s), "FILE  write the relocated binary trace");
      ("--memory_file", Arg.String (fun s -> memory := Some s), "FILE  write the relocated binary memory");
      ("--layout", Arg.Set_string layout, "LAYOUT  builtin layout (default plain)");
      ("--print_output", Arg.Set print_output, " print the output builtin segment");
      ("--entrypoint", Arg.Set_string entry, "NAME  entrypoint (default main)");
      ("--secure_run", Arg.String (fun s -> secure := Some (bool_of s)), "true|false");
      ("--allow_missing_builtins", Arg.String (fun s -> allow_missing := Some (bool_of s)), "true|false");
      ("--fill-holes", Arg.String (fun s -> fill_holes := Some (bool_of s)), "true|false  materialize deducible builtin outputs");
      ("--proof_mode", Arg.Set proof, " run in canonical proof mode");
      ("--air_public_input", Arg.String (fun s -> air_public := Some s), "FILE  write the AIR public input (proof mode)");
      ("--air_private_input", Arg.String (fun s -> air_private := Some s), "FILE  write the AIR private input (proof mode)");
      ("--cairo_pie_output", Arg.String (fun s -> pie_out := Some s), "FILE  write a Cairo PIE zip");
      ("--cairo_layout_params_file", Arg.String (fun s -> layout_params := Some s), "FILE  dynamic layout parameters");
      ("--merge_extra_segments", Arg.Set merge_extra, " merge extra segments in PIE output");
      ("--", Arg.Rest positional, " end of options");
      ("-V", Arg.Unit version, " print version");
      ("--version", Arg.Unit version, " print version");
      ("--stats", Arg.Set stats, " print step count and timing to stderr");
    ]
  in
  let require_backend flag = delegate (flag ^ " requires CAIRO_VM_RUST_CLI") in
  let switches = ["--run_from_cairo_pie"] in
  let spec = spec @ List.map (fun f -> f, Arg.Unit (fun () -> require_backend f), " use the Rust backend") switches in
  let seen = Hashtbl.create 8 in
  let once flag action value =
    if Hashtbl.mem seen flag then raise (Arg.Bad ("option repeated: " ^ flag));
    Hashtbl.add seen flag ();
    action value
  in
  let spec = List.map (fun (flag, action, doc) ->
    let action = match action with
      | Arg.Unit f -> Arg.Unit (once flag f)
      | Arg.String f -> Arg.String (once flag f)
      | Arg.Set r -> Arg.Unit (once flag (fun () -> r := true))
      | Arg.Set_string r -> Arg.String (once flag (fun s -> r := s))
      | other -> other
    in flag, action, doc) spec in
  let usage = "Usage: cairo-vm-cli [OPTIONS] <FILENAME>" in
  let help () = if rust <> None then delegate "help"; print_string (Arg.usage_string spec usage); exit 0 in
  let options = ("-h", Arg.Unit help, " display help") :: spec in
  (try Arg.parse_argv Sys.argv options positional usage with
   | Arg.Bad msg -> if rust <> None then delegate msg else (prerr_string msg; exit 2)
   | Arg.Help msg -> if rust <> None then delegate msg else (print_string msg; exit 0));
  let usage_error msg = if rust <> None then delegate msg else (prerr_endline ("error: " ^ msg); exit 2) in
  (match Runner.layout_builtins !layout with None -> usage_error ("invalid layout: " ^ !layout) | Some _ -> ());
  let file = match !file with Some f -> f | None -> usage_error "missing program file" in
  (* clap constraints of cairo-vm-cli *)
  if !layout = "dynamic" && !layout_params = None then
    usage_error "the following required arguments were not provided: --cairo_layout_params_file";
  if !air_public <> None && not !proof then usage_error "--air_public_input requires --proof_mode";
  if !air_private <> None && not (!proof && !trace <> None && !memory <> None) then
    usage_error "--air_private_input requires --proof_mode, --trace_file and --memory_file";
  if !pie_out <> None && (!proof || !air_public <> None || !air_private <> None) then
    usage_error "--cairo_pie_output cannot be used with --proof_mode or the AIR inputs";
  try
    let t0 = Unix.gettimeofday () in
    let prog = Program.load_file file in
    let proof = !proof in
    let layout_def =
      match !layout_params with
      | Some p -> let l = Layout.dynamic_of_file p in if !layout = "dynamic" then Some l else None
      | None -> None
    in
    let cfg =
      {
        Runner.layout = !layout;
        (* a PIE needs the trace to count memory holes *)
        trace = !trace <> None || !air_public <> None || !pie_out <> None;
        secure_run = Option.value !secure ~default:(not proof);
        allow_missing_builtins = Option.value !allow_missing ~default:proof;
        entrypoint = !entry;
      }
    in
    let r, t1, t2 = try
      let r = Runner.initialize ?layout_def ~proof cfg prog in
      let t1 = Unix.gettimeofday () in
      Runner.run_until_end r;
      let t2 = Unix.gettimeofday () in
      Runner.end_run ~fill_holes:(Option.value !fill_holes ~default:proof) r ~secure:cfg.secure_run
        ~allow_missing:cfg.allow_missing_builtins;
      r, t1, t2
    with Vm.Vm_error msg when rust <> None && not !stats -> delegate msg in
    if !print_output then begin
      print_string "Program Output:\n";
      Runner.iter_output_lines r (fun line -> output_string stdout line; output_char stdout '\n');
      flush stdout
    end;
    Option.iter (Runner.write_trace r) !trace;
    Option.iter (Runner.write_memory r) !memory;
    Option.iter (Air.write_public_input r) !air_public;
    (match !air_private, !trace, !memory with
     | Some p, Some trace_path, Some memory_path -> Air.write_private_input r ~trace_path ~memory_path p
     | _ -> ());
    Option.iter
      (Pie.write r ~main:(Runner.entry_pc cfg prog) ~secure:cfg.secure_run ~merge_extra_segments:!merge_extra) !pie_out;
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
  | Sys_error msg | Failure msg | Yojson.Json_error msg -> prerr_endline ("Error: " ^ msg); exit 1
  | Yojson.Safe.Util.Type_error (msg, _) -> prerr_endline ("Invalid program: " ^ msg); exit 1
