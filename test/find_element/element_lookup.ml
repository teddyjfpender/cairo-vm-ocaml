open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let seg = Vm.add_segment vm and base = Felt.reloc 0 0 in
  let big () = Felt.of_z (Z.shift_left Z.one 160) in
  let put i x = Vm.write vm seg i x in
  let cache = ref None in
  let search n v = Find_element.lookup cache vm base 1 n v in
  List.iteri put [big (); Felt.small 1; big (); base];
  assert (search 4 base = 3);
  assert (search 4 base = 3);
  assert (search 3 (big ()) = 0);
  let error expected f = match f () with
    | exception Vm.Vm_error msg -> assert (msg = expected)
    | _ -> failwith "expected lookup failure" in
  error "Key 0:0 was not found." (fun () -> search 3 base);
  error "Unknown memory cell 0:4" (fun () -> search 6 Felt.zero);
  put 4 Felt.zero;
  assert (search 6 Felt.zero = 4);
  assert (Find_element.lookup cache vm (Felt.reloc 0 1) 1 3 base = 2);
  assert (Find_element.lookup cache vm base 2 3 Felt.zero = 2);
  error "Key 0 was not found." (fun () -> search 0 Felt.zero);
  assert (search 5 Felt.zero = 4);
  let other = Vm.create ~trace:false in
  ignore (Vm.add_segment other);
  Vm.write other 0 0 Felt.zero;
  assert (Find_element.lookup cache other base 1 1 Felt.zero = 0)

let () =
  let rng = Random.State.make [|263; 89|] in
  let vm = Vm.create ~trace:false in
  ignore (Vm.add_segment vm);
  let values = Array.init 2048 (fun i ->
    match i mod 7 with
    | 0 -> Felt.reloc 0 (i mod 13)
    | 1 -> Felt.of_z (Z.add (Z.shift_left Z.one 138) (Z.of_int (i mod 5)))
    | _ -> Felt.small (Random.State.int rng 47)) in
  let written = Array.make (Array.length values) false in
  let put i = Vm.write vm 0 i values.(i); written.(i) <- true in
  Array.iteri (fun i _ -> if i mod 317 <> 201 then put i) values;
  let cache = ref None in
  let observe f = try Ok (f ()) with Vm.Vm_error msg -> Error msg in
  let compare start width length key =
    let reference () =
      let rec loop i =
        if i = length then Vm.fail "Key %s was not found." (Vm.value_to_string key);
        let at = start + i * width in
        if at >= Array.length values || not written.(at) then Vm.fail "Unknown memory cell 0:%d" at;
        if Felt.equal key values.(at) then i else loop (i + 1)
      in loop 0
    in
    let result = observe (fun () ->
      Find_element.lookup cache vm (Felt.reloc 0 start) width length key) in
    assert (result = observe reference)
  in
  for trial = 0 to 5999 do
    let start = trial mod 220 and width = 1 + (trial / 220 mod 3) in
    let key = values.(Random.State.int rng (Array.length values)) in
    compare start width (Random.State.int rng 460) key;
    if trial mod 53 = 0 then compare (max 0 (start - 9)) width 0 key;
    if trial mod 450 = 0 then begin
      let i = 201 + (trial / 450 mod 6) * 317 in
      put i
    end
  done;
  (* Increasing one-cell views should retire all historical distinct keys. *)
  let vm = Vm.create ~trace:false in
  ignore (Vm.add_segment vm);
  for i = 0 to 1023 do Vm.write vm 0 i (Felt.small i) done;
  let cache = ref None in
  for i = 0 to 1022 do
    assert (Find_element.lookup cache vm (Felt.reloc 0 i) 1 2 (Felt.small (i+1)) = 1)
  done;
  match !cache with
  | Some t -> assert (Find_element.Words.length t.first <= 2)
  | None -> assert false
