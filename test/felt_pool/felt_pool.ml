open Cairovm

(* Big felts keep their limbs while many more are allocated, and exhausting
   the fixed reservation fails explicitly instead of overwriting slots. *)
let () =
  let used = !Felt.pool_n in
  let wide i = Z.add (Z.shift_left Z.one (64 + i mod 185)) (Z.of_int i) in
  let entries = Array.init 100_000 (fun i ->
      let c = Felt.of_z (wide i) in
      assert (Felt.is_big c);
      c) in
  assert (!Felt.pool_n = used + Array.length entries);
  Array.iteri (fun i c -> assert (Z.equal (Felt.to_z c) (wide i))) entries;
  Felt.pool_n := Felt.capacity;
  assert (match Felt.of_z (wide 0) with _ -> false | exception Out_of_memory -> true)
