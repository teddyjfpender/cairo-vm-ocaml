(* Persistent OS output benchmark. Load the program once. Every command reads
   the witness from disk and executes a fresh VM, including finalization. *)
open Cairovm

let () =
  Os_hints.configure_batch_gc ();
  let program = Program.load_file Sys.argv.(1) and path = Sys.argv.(2) in
  let image = match Array.to_list Sys.argv with
    | [_;_;_] -> Some (Program_image.prepare program)
    | [_;_;_;"--no-image"] -> None
    | _ -> invalid_arg "native_os_worker PROGRAM INPUT [--no-image]" in
  let cfg = {Runner.layout="all_cairo"; trace=false; secure_run=true; allow_missing_builtins=false; entrypoint="main"} in
  print_endline "READY";
  try while true do
    let line = read_line () in
    let path =
      if line = "RUN" then path else if String.starts_with ~prefix:"RUN " line then
        String.sub line 4 (String.length line-4)
      else invalid_arg "expected RUN or RUN <input path>" in
    Os_hints.run_output_file ?image ~path cfg program
    |> List.iter (fun line -> print_string line; print_char '\n');
    print_endline "DONE"
  done with End_of_file -> ()
