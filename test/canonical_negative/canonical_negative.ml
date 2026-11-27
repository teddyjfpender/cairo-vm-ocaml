open Cairovm

let () =
  let x = Felt.of_z (Z.shift_left Z.one 192) in
  List.iter (fun n ->
    let y = Felt.of_z (Z.add (Felt.to_z x) (Z.of_int n)) in
    let before = !Felt.pool_n in
    let result = Felt.sub x y in
    let expected = Felt.of_z (Z.neg (Z.of_int n)) in
    assert (Z.equal (Felt.to_z result) (Felt.to_z expected));
    assert (Felt.equal result expected);
    if n < Felt.small_bound then begin
      assert (result = Felt.small (-n));
      assert (!Felt.pool_n = before)
    end else assert (Felt.is_big result)
  ) [0; 1; 2; 3; 127; 1024; Felt.small_bound - 1; Felt.small_bound; Felt.small_bound + 1]
