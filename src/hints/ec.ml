(* Stark-curve point hints: random_ec_point and recover_y (cairo-vm
   ec_utils.rs). *)

open Errors
open Vm
open Hintrt
open Secp
module C = Hint_codes

let stark_beta = Z.of_string "3141592653589793238462643383279502884197169399375105820974944592307816406665"

(* 32-byte big-endian encoding of a field element (Felt252::to_bytes_be) *)
let be32 v =
  let b = Bytes.make 32 '\000' in
  let rec fill i v = if i >= 0 && Z.sign v > 0 then (Bytes.set b i (Char.chr (Z.to_int (Z.extract v 0 8))); fill (i - 1) (Z.shift_right v 8)) in
  fill 31 v;
  Bytes.to_string b

let recover_y x =
  let y2 = Z.add (Z.add (Z.powm x (z 3) stark_p) x) stark_beta in
  let residue = Z.sign y2 = 0 || Z.equal y2 Z.one || Z.equal (Z.powm y2 felt_max_halved stark_p) Z.one in
  if residue then felt_sqrt y2 else None

let random_ec_point_seeded seed_bytes =
  let seed = Sha256.digest seed_bytes in
  let rest = String.sub seed 1 31 in
  let y_neg = Char.code seed.[0] land 1 = 1 in
  let rec go i =
    if i >= 100 then fail "Random ec point not on curve"
    else begin
      let input = rest ^ String.make 1 (Char.chr i) ^ String.make 9 '\000' in
      let x = z_of_be (Sha256.digest input) in
      match recover_y x with
      | Some y -> (zf x, zf (if y_neg then Z.neg y else y))
      | None -> go (i + 1)
    end
  in
  go 0

let stark_point vm c name =
  let a = get_addr vm c name in
  (int_at vm a 0, int_at vm a 1)

let write_point vm c name (x, y) =
  let a = get_addr vm c name in
  write_checked vm (Felt.rseg a) (Felt.roff a) x;
  write_checked vm (Felt.rseg a) (Felt.roff a + 1) y

let register reg =
  reg C.random_ec_point (fun c vm ->
      let px, py = stark_point vm c "p" in
      let qx, qy = stark_point vm c "q" in
      let m = get_felt vm c "m" in
      let seed = String.concat "" (List.map (fun v -> be32 (Felt.to_z v)) [ px; py; m; qx; qy ]) in
      write_point vm c "s" (random_ec_point_seeded seed));
  reg C.chained_ec_op_random_ec_point (fun c vm ->
      let n = get_z vm c "len" in
      if Z.sign n = 0 || not (Z.fits_int n) || Z.to_int n < 0 then fail "Invalid value for len. Got: %s" (Z.to_string n);
      let n = Z.to_int n in
      let px, py = stark_point vm c "p" in
      let m = get_ptr vm c "m" and q = get_ptr vm c "q" in
      let range p k = List.init k (fun i -> int_at vm p i) in
      let ms = range m n in
      let qs = range q (2 * n) in
      let seed = String.concat "" (List.map (fun v -> be32 (Felt.to_z v)) ((px :: py :: ms) @ qs)) in
      write_point vm c "s" (random_ec_point_seeded seed));
  reg C.recover_y (fun c vm ->
      let x = get_felt vm c "x" in
      let a = get_addr vm c "p" in
      write_checked vm (Felt.rseg a) (Felt.roff a) x;
      match recover_y (Felt.to_z x) with
      | Some y -> write_checked vm (Felt.rseg a) (Felt.roff a + 1) (zf y)
      | None -> fail "Point (%s, ?) is not on the curve" (Felt.to_string x))
