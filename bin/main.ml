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
         let env = Unix.environment () |> Array.to_list
           |> List.filter (fun entry -> not (String.starts_with ~prefix:"CAIRO_VM_DELEGATED=" entry)) in
         let argv = Array.copy Sys.argv in
         argv.(0) <- path;
         Unix.execve path argv (Array.of_list ("CAIRO_VM_DELEGATED=1" :: env))
       with Failure msg -> prerr_endline msg; exit 2
          | Unix.Unix_error (e, _, _) -> prerr_endline (path ^ ": " ^ Unix.error_message e); exit 2)

let () =
  let file = ref None and trace = ref None and memory = ref None in
  let layout = ref "plain" and print_output = ref false and entry = ref "main" in
  let secure = ref None and allow_missing = ref None and stats = ref false in
  let fill_holes = ref None and proof = ref false and merge_extra = ref false in
  let air_public = ref None and air_private = ref None and pie_out = ref None and layout_params = ref None in
  let from_pie = ref false and os_hints = ref None and bootloader_input = ref None in
  let aggregator_input = ref None and aggregator_da = ref None in
  let positional f = match !file with
    | None -> file := Some f | Some _ -> raise (Arg.Bad "expected one program file") in
  let version () = if rust <> None then delegate "version"; print_endline "cairo-vm-cli 4.0.0 (OxCairo 0.1.0)"; exit 0 in
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
      ("--aggregator_input", Arg.String (fun s -> aggregator_input := Some s), "FILE  read sequencer aggregator input");
      ("--aggregator_da_output", Arg.String (fun s -> aggregator_da := Some s), "FILE  write aggregated blob coefficients");
      ("--bootloader_input", Arg.String (fun s -> bootloader_input := Some s), "FILE  read simple bootloader tasks");
      ("--os_hints", Arg.String (fun s -> os_hints := Some s), "FILE  read sequencer OS hints and block inputs");
      ("--run_from_cairo_pie", Arg.Set from_pie, " the input file is a Cairo PIE zip to re-execute");
      ("--", Arg.Rest positional, " end of options");
      ("-V", Arg.Unit version, " print version");
      ("--version", Arg.Unit version, " print version");
      ("--stats", Arg.Set stats, " print step count and timing to stderr");
    ]
  in
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
  if !from_pie && (!proof || !air_public <> None || !air_private <> None) then
    usage_error "--run_from_cairo_pie cannot be used with --proof_mode or the AIR inputs";
  if !from_pie && Option.is_some !os_hints then usage_error "--os_hints requires a compiled program";
  if Option.is_some !bootloader_input && (!from_pie || Option.is_some !os_hints) then
    usage_error "--bootloader_input requires a compiled bootloader and its own hint processor";
  if Option.is_some !aggregator_input && (!from_pie || Option.is_some !os_hints || Option.is_some !bootloader_input) then
    usage_error "--aggregator_input requires its own compiled program";
  if Option.is_some !aggregator_da && Option.is_none !aggregator_input then
    usage_error "--aggregator_da_output requires --aggregator_input";
  try
    let t0 = Unix.gettimeofday () in
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
    let pie_input = ref None and da_words = ref None in
    let r, t1, t2 = try
      if !from_pie then begin
        let pie,source = Pie_file.read_deferred file in
        let t1 = Unix.gettimeofday () in
        let res =
          Pie_run.run ~source ~layout:!layout ~trace:cfg.trace ~secure:cfg.secure_run
            ~allow_missing_builtins:cfg.allow_missing_builtins ~fill_holes:(Option.value !fill_holes ~default:false) pie
        in
        pie_input := Some res;
        res.runner, t1, Unix.gettimeofday ()
      end else
      let () = if Option.is_some !os_hints then Os_hints.configure_batch_gc () in
      let execute on_pie_loaded =
        let r = match !aggregator_input, !bootloader_input, !os_hints with
          | Some path, _, _ ->
              let on_da = Option.map (fun _ words -> da_words := Some words) !aggregator_da in
              Aggregator.initialize ?layout_def ?on_da ~proof ~path cfg (Program.load_file file)
          | None, Some path, _ -> Bootloader.initialize ~on_pie_loaded ?layout_def ~proof ~path cfg (Program.load_file file)
          | None, _, Some path -> Os_hints.initialize_files ?layout_def ~record_trace:cfg.trace ~proof ~path cfg file
          | None, None, None -> Runner.initialize ?layout_def ~proof cfg (Program.load_file file) in
        let t1 = Unix.gettimeofday () in
        Runner.run_until_end r;
        r, t1, Unix.gettimeofday () in
      let r, t1, t2 = if Option.is_some !bootloader_input then Resources.with_pedersen_verifier execute
        else execute ignore in
      Finalize.end_run ~fill_holes:(Option.value !fill_holes ~default:proof) r ~secure:cfg.secure_run
        ~allow_missing:cfg.allow_missing_builtins;
      r, t1, t2
    with Errors.Vm_error msg when rust <> None && !aggregator_input = None && !os_hints = None && !bootloader_input = None && not !stats -> delegate msg in
    (match !aggregator_da, !da_words with
     | Some file, Some words ->
         Out_channel.with_open_bin file (fun oc ->
             output_char oc '[';
             Array.iteri (fun i word ->
                 if i > 0 then output_char oc ',';
                 Printf.fprintf oc "\"0x%s\"" (Z.format "x" (Felt.to_z word))) words;
             output_char oc ']')
     | _ -> ());
    if !print_output then begin
      print_string "Program Output:\n";
      Artifacts.iter_output_lines r (fun line -> output_string stdout line; output_char stdout '\n');
      flush stdout
    end;
    Artifacts.with_artifacts r ~trace:!trace ~memory:!memory (fun () ->
        Option.iter (Air.write_public_input r) !air_public;
        match !air_private, !trace, !memory with
        | Some p, Some trace_path, Some memory_path -> Air.write_private_input r ~trace_path ~memory_path p
        | _ -> ());
    Option.iter
      (fun path ->
        match !pie_input with
        | Some res ->
            Pie_run.write_output ~secure:cfg.secure_run ~merge_extra_segments:!merge_extra res path
        | None ->
            Pie.write r ~main:(Runner.entry_pc cfg r.prog) ~secure:cfg.secure_run ~merge_extra_segments:!merge_extra path)
      !pie_out;
    if !stats then
      Printf.eprintf "generic=%d hint_pcs=%d " !Cpu.generic_steps !Cpu.hint_steps;
    if !stats then
      Printf.eprintf "steps=%d load=%.3fs run=%.3fs (%.1f Msteps/s) total=%.3fs\n" r.vm.steps (t1 -. t0) (t2 -. t1)
        (float r.vm.steps /. (t2 -. t1) /. 1e6) (Unix.gettimeofday () -. t0)
  with
  | Errors.Vm_error msg ->
      prerr_endline ("Error: " ^ msg);
      exit 1
  | Program.Parse_error msg ->
      prerr_endline ("Error: " ^ msg);
      exit 1
  | Sys_error msg | Failure msg | Yojson.Json_error msg -> prerr_endline ("Error: " ^ msg); exit 1
  | Yojson.Safe.Util.Type_error (msg, _) -> prerr_endline ("Invalid program: " ^ msg); exit 1
