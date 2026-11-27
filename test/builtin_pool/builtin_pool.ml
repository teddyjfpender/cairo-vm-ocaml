open Cairovm

(* A multi-cell kernel block that straddles a pool growth boundary must
   produce the same outputs as a fresh computation, and only big outputs may
   consume pool slots. *)
let () =
  let big = Felt.of_z (Z.shift_left Z.one 190) in
  let words = [| Felt.zero; big; Felt.one; big; big; Felt.zero; big; Felt.one |] in
  while !Felt.pool_n < (Bytes.length !Felt.pool / 32) - 1 do
    ignore (Felt.of_z (Z.shift_left Z.one 180))
  done;
  let start = !Felt.pool_n in
  let across = Felt.keccak words in
  let bigs = Array.fold_left (fun n v -> if Felt.is_big v then n + 1 else n) 0 across in
  assert (!Felt.pool_n = start + bigs);
  let fresh = Felt.keccak words in
  Array.iteri (fun i v -> assert (Felt.equal v fresh.(i))) across
