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

let () =
  let check_hex x =
    let s = "0x" ^ Z.format "%x" x in
    let expected = if Z.lt x Felt.p then Some x else None in
    assert (Option.map Felt.to_z (Felt.of_hex_opt s) = expected)
  in
  List.iter (fun n ->
      let x = Z.shift_left Z.one n in
      List.iter check_hex [Z.pred x; x; Z.succ x]) [0; 59; 63; 64; 127; 192; 251; 255];
  List.iter check_hex [Z.pred Felt.p; Felt.p; Z.succ Felt.p];
  List.iter (fun s -> assert (Felt.of_hex_opt s = None)) [""; "0x"; "00"; "0x10_0"; "0x4g"];
  assert (Option.map Felt.to_z (Felt.of_hex_opt "0X00AF") = Some (Z.of_int 175))

let () =
  List.iter (fun i ->
      assert (Z.equal (Felt.to_z (Felt.of_int i)) (Z.erem (Z.of_int i) Felt.p)))
    [min_int; min_int/2; -Felt.small_bound; Felt.small_bound; max_int/2; max_int]

let () =
  let p = Felt.p and state = Random.State.make [|137; 192|] in
  for i = 0 to 99 do
    let x = if i < 2 then Z.of_int i else
      Z.erem (Z.of_bits (String.init 32 (fun _ -> Char.chr (Random.State.int state 256)))) p in
    let square = Z.erem (Z.mul x x) p in
    assert (Stark_sqrt.sqrt square = Some (Z.min x (Z.sub p x)));
    if Z.sign x <> 0 then assert (Stark_sqrt.sqrt (Z.mul (Z.of_int 3) square) = None)
  done
