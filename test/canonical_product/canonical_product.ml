open Cairovm

let check x y =
  let actual = Felt.mul (Felt.of_z x) (Felt.of_z y) in
  assert (Z.equal (Felt.to_z actual) (Z.erem (Z.mul x y) Felt.p))

let () =
  let corners = ref [Z.zero; Z.one; Z.pred Felt.p] in
  List.iter (fun n ->
    let x = Z.shift_left Z.one n in
    List.iter (fun v -> corners := v :: Z.sub Felt.p v :: !corners)
      [Z.pred x; x; Z.succ x]) [59; 64; 127; 128; 191; 192; 250; 251];
  List.iter (fun x -> List.iter (check x) !corners) !corners;
  let state = Random.State.make [|481|] in
  let random () =
    let z = ref Z.zero in
    for _ = 1 to 9 do
      z := Z.logor (Z.shift_left !z 30) (Z.of_int (Random.State.bits state))
    done;
    Z.erem !z Felt.p
  in
  for _ = 1 to 65536 do check (random ()) (random ()) done
