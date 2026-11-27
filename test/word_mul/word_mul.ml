open Cairovm

let check x k =
  let a = Felt.of_z x and b = Felt.small k in
  let expected = Felt.of_z Z.(mul x (of_int k)) in
  assert (Felt.equal (Felt.mul a b) expected);
  assert (Felt.equal (Felt.mul b a) expected)

let () =
  let edge = Felt.small_bound - 1 in
  let xs = [Z.zero; Z.one; Z.pred Felt.p; Z.of_int edge;
            Z.shift_left Z.one 192; Z.sub Felt.p (Z.shift_left Z.one 64)] in
  List.iter (fun x -> List.iter (check x) [0;1;-1;2;-2;edge;-edge]) xs;
  let rng = Random.State.make [|0x251; 17|] in
  for _ = 1 to 50_000 do
    let x = ref Z.zero in
    for _ = 1 to 9 do
      x := Z.logor (Z.shift_left !x 30) (Z.of_int (Random.State.bits rng))
    done;
    let k = Random.State.int rng (1 lsl 29) lor (Random.State.bits rng lsl 29) in
    check !x (if Random.State.bool rng then k else -k)
  done
