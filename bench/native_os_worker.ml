(* Persistent OS output benchmark. Load the program once. Every command reads
   the witness from disk and executes a fresh VM, including finalization. *)
open Cairovm

let () =
  Os_hints.configure_batch_gc ();
  let program = Program.load_file Sys.argv.(1) and path = Sys.argv.(2) in
  let cfg = {Runner.layout="all_cairo"; trace=false; secure_run=true; allow_missing_builtins=false; entrypoint="main"} in
  print_endline "READY";
  try while true do
    if read_line () <> "RUN" then invalid_arg "expected RUN";
    let r = Os_hints.initialize ~proof:false ~record_trace:false ~path cfg program in
    Runner.run_until_end r;
    Finalize.end_run r ~secure:true ~allow_missing:false;
    Artifacts.iter_output_lines r (fun line -> print_string line; print_char '\n');
    print_endline "DONE"
  done with End_of_file -> ()
