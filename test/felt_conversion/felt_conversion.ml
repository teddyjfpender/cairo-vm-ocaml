open Cairovm

let check z =
  let expected = Z.erem z Felt.p in
  let code = Felt.of_z z in
  assert (Z.equal (Felt.to_z code) expected);
  let limit = Z.of_int Felt.small_bound in
  assert (Felt.is_small code =
    (Z.lt expected limit || Z.gt expected (Z.sub Felt.p limit)))

let () =
  let open Z in
  List.iter (fun point ->
    List.iter (fun n -> check n; check (neg n); check (add n Felt.p))
      [pred point; point; succ point])
    [zero; shift_left one 59; shift_left one 64; shift_left one 128;
     shift_left one 192; Felt.p; shift_left one 512];
  let state = Random.State.make [|0xCA10|] in
  for i = 0 to 9999 do
    let bytes = String.init (Stdlib.(mod) i 65)
      (fun _ -> Char.chr (Random.State.int state 256)) in
    let x = of_bits bytes in
    check (if Stdlib.(i land 1) = 0 then x else neg x)
  done;
  (* Builtins may leave data in the next uncommitted slot. *)
  Felt.reserve 1;
  Bytes.fill !Felt.pool (Stdlib.( * ) !Felt.pool_n 32) 32 '\255';
  check (shift_left one 64)
