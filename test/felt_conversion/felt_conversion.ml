open Cairovm

let check z =
  let expected = Z.erem z Felt.p in
  let code = Felt.of_z z in
  assert (Z.equal (Felt.to_z code) expected);
  let limit = Z.of_int Felt.small_bound in
  assert (Felt.is_small code =
    (Z.lt expected limit || Z.gt expected (Z.sub Felt.p limit)))

let () =
  let pow2 n = Z.shift_left Z.one n in
  List.iter (fun point ->
    List.iter (fun n -> check n; check (Z.neg n); check (Z.add n Felt.p))
      [Z.pred point; point; Z.succ point])
    [Z.zero; pow2 59; pow2 64; pow2 128; pow2 192; Felt.p; pow2 512];
  let state = Random.State.make [|0xCA10|] in
  for i = 0 to 9999 do
    let bytes = String.init (i mod 65)
      (fun _ -> Char.chr (Random.State.int state 256)) in
    let x = Z.of_bits bytes in
    check (if i land 1 = 0 then x else Z.neg x)
  done;
  (* Builtins may leave data in the next uncommitted slot. *)
  Felt.reserve 1;
  Bigarray.Array1.(fill (sub Felt.pool (!Felt.pool_n * 32) 32) '\255');
  check (pow2 64)
