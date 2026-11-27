(* BLS12-381 scalar arithmetic hints, using the Cairo BigInt3 signed limbs. *)
open Errors
open Hintrt

let modulus = Z.of_string "52435875175126190479447740508185965837690552500527637822603658699938581184513"
let base = Z.shift_left Z.one 86

let split value =
  let q, low = Z.div_rem value base in
  let high, middle = Z.div_rem q base in
  if Z.numbits high > 127 then fail "BLS high limb exceeds 127 bits";
  List.map Felt.of_z [low; middle; high]

let register reg =
  reg {|from starkware.starknet.core.os.data_availability.bls_utils import BLS_PRIME, pack, split

a = pack(ids.a, PRIME)
b = pack(ids.b, PRIME)

q, r = divmod(a * b, BLS_PRIME)

# By the assumption: |a|, |b| < 2**104 * ((2**86) ** 2 + 2**86 + 1) < 2**276.001.
# Therefore |q| <= |ab| / BLS_PRIME < 2**299.
# Hence the absolute value of the high limb of split(q) < 2**127.
segments.write_arg(ids.q.address_, split(q))
segments.write_arg(ids.res.address_, split(r))|} (fun c vm ->
      let pack name =
        let address = get_addr vm c name in
        let limb i = as_int (z_at vm address i) in
        Z.add (limb 0) (Z.shift_left (Z.add (limb 1) (Z.shift_left (limb 2) 86)) 86) in
      let q, r = Z.ediv_rem (Z.mul (pack "a") (pack "b")) modulus in
      write_arg vm (get_addr vm c "q") (split q);
      write_arg vm (get_addr vm c "res") (split r))
