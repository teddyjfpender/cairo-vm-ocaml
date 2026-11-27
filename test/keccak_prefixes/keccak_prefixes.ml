open Cairovm

let make_memory () =
  let vm = Vm.create ~trace:false in
  let seg = Vm.add_segment vm in
  vm, Felt.reloc seg 0

let () =
  let vm, base = make_memory () in
  let expected = Bytes.create (16 * 4100) in
  for i = 0 to 4099 do
    let word = Z.(add (shift_left one 110) (of_int i)) in
    Vm.write vm (Felt.rseg base) i (Felt.of_z word);
    for j = 0 to 15 do
      Bytes.set expected (16*i + 15-j) (Char.chr (Z.to_int (Z.extract word (8*j) 8)))
    done
  done;
  let cursor = Hints.keccak_cursors () in
  let check first n =
    let digest = Hints.finalize_keccak cursor vm (Felt.reloc 0 first) n in
    assert (digest = Hints.keccak256 (Bytes.sub expected (16*first) (16*n)))
  in
  List.iter (check 0) [0;1;8;9;16;17;18;17;4000;4100;4100;4096];
  (* Reference digests from eth_hash.auto.keccak over 16-byte BE words. *)
  let hex bytes = String.concat "" (List.init (Bytes.length bytes)
    (fun i -> Printf.sprintf "%02x" (Bytes.get_uint8 bytes i))) in
  assert (hex (Hints.finalize_keccak cursor vm base 0) =
    "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  assert (hex (Hints.finalize_keccak cursor vm base 17) =
    "a2ec22f2f2d5f5d30fce227c5d29939d57cc59a367f3560123720d2f92ecbe28");
  assert (hex (Hints.finalize_keccak cursor vm base 4100) =
    "9f9f41889bcd07fc4d45e22cf1883f0eb7db54c65903fd6d455bf794020fbdb2");
  for length = 0 to 21 do
    for start = 0 to 3 do check start length done
  done;
  (* Evict entries, revisit dropped starts, then rewind an existing one. *)
  List.iter (fun start -> check start 300) [4;5;6;7;8;2;4;3;1;0];
  check 2 4001;
  (match Hints.finalize_keccak cursor vm base 4101 with
   | exception Vm.Vm_error _ -> () | _ -> assert false);
  check 0 4100;
  let other, ptr = make_memory () in
  Vm.write other 0 0 Felt.zero;
  assert (Hints.finalize_keccak cursor other ptr 1 = Hints.keccak256 (Bytes.make 16 '\000'));
  for n = 1 to 16 do
    let single, ptr = make_memory () in
    let largest = Z.pred (Z.shift_left Z.one (8*n)) in
    Vm.write single 0 0 (Felt.of_z largest);
    assert (Hints.keccak_input single ptr ~first:0 n ~check_width:true = Bytes.make n '\255');
    Vm.write single 0 1 (Felt.of_z (Z.succ largest));
    match Hints.keccak_input single ptr ~first:1 n ~check_width:true with
    | exception Vm.Vm_error _ -> () | _ -> assert false
  done
