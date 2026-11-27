(* Embed groups of bytes as one OCaml string, independent of the install path. *)
let () =
  let data = In_channel.with_open_bin Sys.argv.(1) In_channel.input_all in
  if String.length data <> 4096 * 48 then failwith "Invalid BLS12-381 monomial setup length";
  Printf.printf "let points = %S\n" data
