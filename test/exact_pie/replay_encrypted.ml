(* This test driver uses the public test committee's synthetic entropy. *)
open Cairovm

let () =
  if Array.length Sys.argv <> 6 then failwith "expected PROGRAM WITNESS OUTPUT TRACE MEMORY";
  let program = Program.load_file Sys.argv.(1) in
  let cfg = Runner.{layout = "all_cairo"; trace = true; secure_run = true;
                    allow_missing_builtins = false; entrypoint = "main"} in
  let draws = ref 0 in
  let entropy_source () =
    incr draws;
    if !draws <> 1 then failwith "fixture consumed extra entropy";
    String.init 32 Char.chr
  in
  let runner = Os_hints.initialize ~entropy_source ~proof:false ~path:Sys.argv.(2) cfg program in
  Runner.run_until_end runner;
  Finalize.end_run ~disable_trace_padding:false ~fill_holes:false runner ~secure:true ~allow_missing:false;
  if !draws <> 1 then failwith "fixture did not execute the encryption hint";
  Pie.write ~profile:Pie_zip.Rust_3_2 runner ~main:(Runner.entry_pc cfg program) ~secure:true
    ~merge_extra_segments:false Sys.argv.(3);
  Artifacts.write_trace runner Sys.argv.(4);
  Artifacts.write_memory runner Sys.argv.(5)
