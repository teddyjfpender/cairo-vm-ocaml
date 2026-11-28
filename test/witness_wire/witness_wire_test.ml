open Cairovm

let with_file f =
  let p = Filename.temp_file "oxcairo-wire" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove p) (fun () -> f p)

let refuses f =
  match f () with
  | exception Yojson.Json_error _ -> ()
  | _ -> failwith "expected typed wire rejection"

let read p = match Witness_wire.read_file ~resident:true p with
  | Binary doc -> doc | Json _ -> failwith "expected binary witness"

let roundtrip value =
  with_file (fun p ->
      Out_channel.with_open_bin p (fun ch -> Witness_wire.write ch value);
      read p)

let class_doc words side =
  `Assoc ["os_input", `Assoc ["compiled_classes", `Assoc [
      "0x99", `Assoc ["bytecode", `List words; "marker", `Int side]]]]

let bytes_doc s =
  "\xa1\x68os_input\xa1\x70compiled_classes\xa1\x61x\xa1\x68bytecode" ^ s

let () =
  let scalars = `Assoc ["test", `List [
      `Null; `Bool true; `Bool false; `Int (-12); `Int max_int; `Int min_int;
      `Float 1.125; `String "🌍"; `Intlit "18446744073709551615";
      `Intlit "-18446744073709551616"; `Intlit (Z.to_string Felt.p)]] in
  assert (roundtrip scalars = scalars);
  assert (Witness_wire.decode "\xa1\x61x\x81\x18\xff" = `Assoc ["x", `List [`Int 255]]);
  let prime_bytes = Z.to_bits Felt.p in
  List.iter (fun body -> refuses (fun () -> Witness_wire.decode body)) [
    ""; "\x80"; "\xa0\xa0"; "\xa2\x61x\x00\x61x\x01"; "\xbf\xff";
    "\xa1\x61x\x5f"; "\xa1\x61x\xfb\x7f\xf0\x00\x00\x00\x00\x00\x00";
    "\xa1\x61x\x61\xff"; "\xa1\x61x\x9a\xff\xff\xff\xff";
    "\xa1\x61x" ^ String.make 257 '\x81' ^ "\x00";
    bytes_doc "\x44\x00\x00\x00\x01";
    bytes_doc "\x46\x00\x00\x00\x01\x01\x00";
    bytes_doc ("\x58\x25\x00\x00\x00\x01\x20" ^ String.sub prime_bytes 0 32)];
  List.iter (fun frame -> with_file (fun p ->
      Out_channel.with_open_bin p (fun ch -> output_string ch frame);
      refuses (fun () -> Witness_wire.read_file p)))
    ["OXW2"; "OXW1"; "OXW1\xff\xff\xff\xff"; "OXW1\x00\x00\x00\x01";
     "OXW1\x00\x00\x00\x01\xa0\x00"];
  let expected = [Z.zero; Z.of_int 256; Z.pred Felt.p] in
  let values = List.map (fun z -> `String ("0x" ^ Z.format "x" z)) expected in
  List.iter (fun marker ->
      let doc = roundtrip (class_doc values marker) in
      let get = Yojson.Safe.Util.member in
      let c = get "0x99" (get "compiled_classes" (get "os_input" doc)) in
      assert (get "marker" c = `Int marker);
      match get "bytecode" c with
      | `Variant ("OXW1.words", Some (`String raw)) ->
          Felt.with_temporary_slots (fun () ->
              assert (Array.to_list (Array.map Felt.to_z (Witness_words.decode raw)) = expected))
      | _ -> failwith "expected packed class code") [1; 1; 2; 1]
