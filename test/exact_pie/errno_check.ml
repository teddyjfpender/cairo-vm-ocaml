open Cairovm

let () =
  let path = Sys.argv.(1) in
  let member sink = let bytes = Bytes.make 8192 'x' in sink bytes (Bytes.length bytes) in
  match Pie_zip.write ~profile:Rust_3_2 ~level:0 path [ "sample", member ] with
  | () -> failwith "archive exceeded its output limit"
  | exception Unix.Unix_error (Unix.EFBIG, _, _) ->
      if Sys.file_exists path then failwith "published incomplete archive"
