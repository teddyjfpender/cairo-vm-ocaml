open Cairovm

let () =
  let big = Z.shift_left Z.one 190 in
  let hex = "0x" ^ Z.format "%x" big in
  let check token =
    Felt.with_temporary_slots (fun () ->
        let start = !Felt.pool_n in
        let raw = Printf.sprintf {|["%s",%s,"0xff"]|} hex token in
        let values = Aggregator_output.decode_input raw |> Array.map Felt.to_z in
        if not (Array.for_all2 Z.equal values [|big; Z.of_int 15; Z.of_int 255|]) then
          failwith (raw ^ " produced " ^ String.concat "," (List.map Z.to_string (Array.to_list values)));
        (* The first wide value is decoded speculatively before the fallback.
           Only the committed value consumes a slot. *)
        assert (!Felt.pool_n = start + 1)) in
  List.iter check [{|"0xf"|}; "15"; {|"0\u0078f"|}];
  assert (Aggregator_output.decode_input "[]" = [||]);
  match Aggregator_output.decode_input {|["0x1",-1]|} with
  | exception Errors.Vm_error _ -> ()
  | _ -> failwith "negative OS word accepted"
