open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let base = Vm.add_segment vm in
  let b = {Vm.kind = Vm.Bitwise; base; included = true; stop_ptr = 0; cache = [||]} in
  let at = ref 0 in
  let check x y =
    let off = !at in
    at := off + 5;
    Vm.write vm base off (Felt.of_z x);
    Vm.write vm base (off+1) (Felt.of_z y);
    let outputs = [|Z.logand x y; Z.logxor x y; Z.logor x y|] in
    List.iter (fun k ->
      let c = Vm.deduce_builtin vm b base (off + 2 + k) in
      assert (Z.equal (Felt.to_z c) outputs.(k)))
      [2; 0; 1; 2]
  in
  let magnitudes = List.map (fun bit -> Z.pred (Z.shift_left Z.one bit))
      [0; 1; 31; 58; 59; 60; 120; 250; 251] in
  List.iter (fun a -> List.iter (check a) magnitudes) magnitudes;
  let rng = Random.State.make [|591|] in
  for _ = 1 to 2048 do
    let number () = Z.logor (Z.shift_left (Z.of_int (Random.State.bits rng)) 28)
                          (Z.of_int (Random.State.bits rng)) in
    check (number ()) (number ())
  done;
  List.iter (fun invalid ->
    let off = !at in at := off + 5;
    Vm.write vm base off Felt.one;
    Vm.write vm base (off+1) (Felt.of_z invalid);
    match Vm.deduce_builtin vm b base (off+2) with
    | exception Vm.Vm_error msg ->
        assert (msg = Printf.sprintf "Bitwise builtin: integer at %d:%d is bigger than 2^251" base (off+1))
    | _ -> assert false) [Z.minus_one; Z.shift_left Z.one 251]
