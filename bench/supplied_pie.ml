(* Supplied witnesses use one pinned program and a fresh secure VM per request.
   --worker accepts tab-separated WITNESS and OUTPUT paths on standard input. *)
open Cairovm

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let program_path, profile, inputs = match args with
    | program :: "--worker" :: [profile] when profile = "stored" || profile = "standard" ->
        program, profile, None
    | program :: (_ :: _ as pairs) when List.length pairs mod 2 = 0 ->
        program, "stored", Some pairs
    | _ -> invalid_arg "supplied_pie PROGRAM --worker stored|standard or PROGRAM WITNESS OUTPUT [WITNESS OUTPUT ...]" in
  Os_hints.configure_batch_gc ();
  let now = Unix.gettimeofday in
  let started = now () in
  let program = Program.load_file program_path in
  let image = Program_image.prepare program in
  Printf.printf "{\"compiler_prepare_s\":%.9f}\n%!" (now () -. started);
  let cfg = {Runner.layout="all_cairo"; trace=true; secure_run=true;
             allow_missing_builtins=false; entrypoint="main"} in
  let run path output =
    let started = now () in
    let initialized, executed, finalized, published = Felt.with_temporary_slots (fun () ->
      let r = Os_hints.initialize ~image ~proof:false ~record_trace:true ~path cfg program in
      let initialized = now () in
      Runner.run_until_end r;
      let executed = now () in
      Finalize.end_run r ~secure:true ~allow_missing:false;
      let finalized = now () in
      Pie.write ~profile:(if profile = "stored" then Pie_zip.Fast else Pie_zip.Rust_3_2)
        ~compression_level:0 ~merge_extra_segments:false
        ~main:(Runner.entry_pc cfg program) ~secure:true r output;
      initialized, executed, finalized, now ()) in
      Printf.printf
        "{\"initialize_s\":%.9f,\"execute_s\":%.9f,\"finalize_s\":%.9f,\"store_s\":%.9f,\"total_s\":%.9f}\n%!"
        (initialized -. started) (executed -. initialized) (finalized -. executed)
        (published -. finalized) (now () -. started) in
  match inputs with
  | Some pairs ->
      let rec consume = function
        | path :: output :: rest -> run path output; consume rest
        | [] -> ()
        | _ -> assert false in
      consume pairs
  | None ->
      try while true do
        match String.split_on_char '\t' (read_line ()) with
        | [path; output] -> run path output
        | _ -> invalid_arg "expected WITNESS<TAB>OUTPUT"
      done with End_of_file -> ()
