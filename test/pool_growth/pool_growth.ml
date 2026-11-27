open Cairovm

let () =
  let used = !Felt.pool_n in
  let capacity = Bytes.length !Felt.pool in
  let wide i = Z.add (Z.shift_left Z.one (64 + i mod 185)) (Z.of_int i) in
  let entries = Array.init (4 * capacity / 32) (fun i ->
      let z = wide i in
      let c = Felt.of_z z in
      assert (Felt.is_big c);
      c) in
  assert (Bytes.length !Felt.pool > capacity);
  assert (!Felt.pool_n = used + Array.length entries);
  Array.iteri (fun i c -> assert (Z.equal (Felt.to_z c) (wide i))) entries
