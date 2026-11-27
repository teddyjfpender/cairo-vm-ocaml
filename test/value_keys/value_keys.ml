open Cairovm

let sign n = Stdlib.compare n 0

let ordering a b =
  match Felt.is_felt a, Felt.is_felt b with
  | true, true -> Z.compare (Felt.to_z a) (Felt.to_z b)
  | true, false -> -1
  | false, true -> 1
  | false, false -> Stdlib.compare (Felt.rseg a, Felt.roff a) (Felt.rseg b, Felt.roff b)

let () =
  let values = ref [Felt.zero; Felt.one; Felt.small (-1)] in
  List.iter (fun seg ->
    List.iter (fun off -> values := Felt.reloc seg off :: !values)
      [0; 1; Felt.off_mask]) [-100; -1; 0; 1; 100];
  let state = Random.State.make [|2509|] in
  for i = 1 to 256 do
    let word = Random.State.bits state + 1 and shift = i mod 221 in
    let z = Z.(add (shift_left (of_int word) shift) (of_int i)) in
    let x = Felt.of_z z and y = Felt.of_z z in
    assert (Felt.hash x = Felt.hash y);
    assert (Hintrt.canon x = Hintrt.canon y);
    if Felt.is_big x then assert (x <> y);
    values := x :: Felt.neg x :: !values
  done;
  List.iter (fun a -> List.iter (fun b ->
    assert (sign (Hintrt.compare_values a b) = sign (ordering a b))) !values) !values

let () =
  let z = Z.shift_left Z.one 186 in
  let outer = Felt.intern (Felt.of_z z) in
  let first = !Felt.pool_n in
  (match Felt.with_temporary_slots (fun () ->
       let inner = Felt.intern (Felt.of_z z) in
       assert (inner <> outer && Felt.intern (Felt.of_z z) = inner);
       raise Exit) with exception Exit -> () | _ -> assert false);
  assert (!Felt.pool_n = first && Felt.intern (Felt.of_z z) = outer);
  Felt.with_temporary_slots (fun () ->
      let original = Felt.of_z z in
      let copy = Felt.of_z z in
      let map = Hintrt.Dict_changes.singleton original Felt.one in
      assert (original <> copy && Hintrt.Dict_changes.find copy map = Felt.one))
