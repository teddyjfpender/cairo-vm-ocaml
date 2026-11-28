open Cairovm

let () =
  if Array.length Sys.argv <> 3 then begin
    prerr_endline "usage: oxcairo-pack-witness INPUT.json OUTPUT.oxw"; exit 2
  end;
  try
    let input = Sys.argv.(1) and output = Sys.argv.(2) in
    let stat = Unix.LargeFile.stat input in
    if stat.st_kind <> Unix.S_REG || stat.st_size > Int64.of_int Witness_wire.max_bytes then
      failwith "expected a regular JSON witness of at most 256 MiB";
    (match Unix.LargeFile.stat output with
     | other when other.st_dev = stat.st_dev && other.st_ino = stat.st_ino ->
         failwith "input and output must be distinct"
     | _ -> () | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    let doc = Json_reader.from_file input in
    let tmp, ch = Filename.open_temp_file ~temp_dir:(Filename.dirname output)
        ~mode:[Open_binary] "oxcairo-witness-" ".tmp" in
    Fun.protect ~finally:(fun () -> close_out_noerr ch; if Sys.file_exists tmp then Sys.remove tmp)
      (fun () -> Witness_wire.write ch doc; close_out ch; Sys.rename tmp output)
  with Errors.Vm_error msg | Invalid_argument msg | Sys_error msg | Failure msg | Yojson.Json_error msg ->
    prerr_endline msg; exit 1
     | Stack_overflow | Out_of_memory -> prerr_endline "witness packing resource limit"; exit 1
     | Unix.Unix_error (err, _, _) -> prerr_endline (Unix.error_message err); exit 1
