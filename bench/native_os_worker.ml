(* Persistent OS output benchmark. Load the program once. Every command reads
   the witness from disk and executes a fresh VM, including finalization. *)
open Cairovm

let () =
  Os_hints.configure_batch_gc ();
  let program = Program.load_file Sys.argv.(1) and path = Sys.argv.(2) in
  let options = Array.to_list Sys.argv |> List.filteri (fun i _ -> i >= 3) in
  let kind = ref `Os and prepare = ref true in
  List.iter (function
    | "--no-image" -> prepare := false
    | "--virtual-os" -> kind := `Virtual
    | "--aggregator" -> kind := `Aggregator
    | _ -> invalid_arg "native_os_worker PROGRAM INPUT [--no-image] [--virtual-os | --aggregator]") options;
  let image = if !prepare then Some (Program_image.prepare program) else None in
  let cfg = {Runner.layout="all_cairo"; trace=false; secure_run=true; allow_missing_builtins=false; entrypoint="main"} in
  let execute path = match !kind with
    | `Os | `Virtual -> Os_hints.run_output_file ~virtual_os:(!kind = `Virtual) ?image ~path cfg program
    | `Aggregator ->
        Felt.with_temporary_slots (fun () ->
            let r = Aggregator.initialize ?image ~proof:false ~path cfg program in
            Runner.run_until_end r;
            Finalize.end_run r ~secure:cfg.secure_run ~allow_missing:cfg.allow_missing_builtins;
            Artifacts.output_lines r) in
  print_endline "READY";
  try while true do
    let line = read_line () in
    let path =
      if line = "RUN" then path else if String.starts_with ~prefix:"RUN " line then
        String.sub line 4 (String.length line-4)
      else invalid_arg "expected RUN or RUN <input path>" in
    execute path
    |> List.iter (fun line -> print_string line; print_char '\n');
    print_endline "DONE"
  done with End_of_file -> ()
