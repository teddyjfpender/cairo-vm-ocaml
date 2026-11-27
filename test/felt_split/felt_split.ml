open Cairovm

let check z =
  let c = Felt.of_z z in
  List.iter (fun (two_limbs, width) ->
      let lo, hi = Felt.split_at_limb ~two_limbs c in
      let canonical = Z.erem z Felt.p in
      assert (Z.equal (Felt.to_z lo) (Z.extract canonical 0 width));
      assert (Z.equal (Felt.to_z hi) (Z.shift_right canonical width)))
    [false, 64; true, 128]

let () =
  List.iter (fun bit ->
      let x = Z.shift_left Z.one bit in
      List.iter (fun z -> check z; check (Z.neg z)) [Z.pred x; x; Z.succ x])
    [0; 58; 59; 63; 64; 65; 127; 128; 129; 191; 192; 250; 251];
  let state = Random.State.make [|87|] in
  for _ = 1 to 16384 do
    let x = ref Z.zero in
    for _ = 0 to 8 do
      x := Z.logor (Z.shift_left !x 30) (Z.of_int (Random.State.bits state))
    done;
    check !x
  done
