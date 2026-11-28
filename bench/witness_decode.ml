(* Compare one prepared program and one freshly read witness per job. Each
   output is verified outside the measured read-to-stored-PIE interval. *)
open Cairovm

let check_archive output reference =
  let a = Bytes.create 65536 and b = Bytes.create 65536 in
  In_channel.with_open_bin reference (fun left -> In_channel.with_open_bin output (fun right ->
      let left_size = in_channel_length left in
      if left_size <> in_channel_length right then failwith "PIE length differs";
      let rec compare remaining =
        if remaining > 0 then begin
          let n = min remaining (Bytes.length a) in
          really_input left a 0 n; really_input right b 0 n;
          if not (Bytes.equal a b) then failwith "PIE differs";
          compare (remaining-n)
        end in
      compare left_size))

let () =
  if Array.length Sys.argv <> 8 then
    failwith "witness_decode PROGRAM FIRST_INPUT NEXT_INPUT OUTPUT FIRST_REF NEXT_REF JOBS";
  Os_hints.configure_batch_gc ();
  let program = Program.load_file Sys.argv.(1) in
  let image = Program_image.prepare program in
  let cfg = Runner.{layout="all_cairo"; trace=true; secure_run=true; allow_missing_builtins=false; entrypoint="main"} in
  for job = 1 to int_of_string Sys.argv.(7) do
    let input_path = if job = 1 then Sys.argv.(2) else Sys.argv.(3) in
    let reference = if job = 1 then Sys.argv.(5) else Sys.argv.(6) in
    Felt.with_temporary_slots (fun () ->
        let start = Unix.gettimeofday () in
        let input = Os_hints.read_witness ~resident:true input_path in
        let decoded = Unix.gettimeofday () in
        let runner = Os_hints.initialize_input ~image ~proof:false input cfg program in
        Runner.run_until_end runner;
        Finalize.end_run runner ~secure:true ~allow_missing:false;
        Pie.write ~compression_level:0 runner ~main:(Runner.entry_pc cfg program)
          ~secure:true ~merge_extra_segments:false Sys.argv.(4);
        let done_at = Unix.gettimeofday () in
        check_archive Sys.argv.(4) reference;
        Printf.printf "%d,%.4f,%.4f\n%!" job (1000. *. (decoded -. start))
          (1000. *. (done_at -. start)))
  done
