(* Run a series of supplied witnesses in one pinned compiler process. Each
   request gets a fresh secure VM and writes its complete stored PIE. *)
open Cairovm

let () =
  if Array.length Sys.argv < 4 || Array.length Sys.argv mod 2 <> 0 then
    invalid_arg "supplied_pie PROGRAM WITNESS OUTPUT [WITNESS OUTPUT ...]";
  Os_hints.configure_batch_gc ();
  let now = Unix.gettimeofday in
  let started = now () in
  let program = Program.load_file Sys.argv.(1) in
  let image = Program_image.prepare program in
  Printf.printf "{\"compiler_prepare_s\":%.9f}\n%!" (now () -. started);
  let cfg = {Runner.layout="all_cairo"; trace=true; secure_run=true;
             allow_missing_builtins=false; entrypoint="main"} in
  let run path output = Felt.with_temporary_slots (fun () ->
      let started = now () in
      let r = Os_hints.initialize ~image ~proof:false ~record_trace:true ~path cfg program in
      let initialized = now () in
      Runner.run_until_end r;
      let executed = now () in
      Finalize.end_run r ~secure:true ~allow_missing:false;
      let finalized = now () in
      Pie.write ~profile:Pie_zip.Fast ~compression_level:0 ~merge_extra_segments:false
        ~main:(Runner.entry_pc cfg program) ~secure:true r output;
      let published = now () in
      Printf.printf
        "{\"initialize_s\":%.9f,\"execute_s\":%.9f,\"finalize_s\":%.9f,\"store_s\":%.9f,\"total_s\":%.9f}\n%!"
        (initialized -. started) (executed -. initialized) (finalized -. executed)
        (published -. finalized) (published -. started)) in
  for i = 1 to (Array.length Sys.argv - 2) / 2 do
    run Sys.argv.(2*i) Sys.argv.(2*i+1)
  done
