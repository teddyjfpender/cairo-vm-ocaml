(* Uint384 / Uint512 arithmetic and modular square roots (cairo-vm
   uint384.rs, uint384_extension.rs, field_arithmetic.rs, vrf/). *)

open Errors
open Hintrt
open Secp
module C = Hint_codes

(* BigIntN::pack: unsigned 128-bit limbs *)
let pack128 vm c name n =
  let a = get_addr vm c name in
  let r = ref Z.zero in
  for i = n - 1 downto 0 do
    r := Z.add (Z.shift_left !r 128) (z_at vm a i)
  done;
  !r

(* BigIntN::split: n masked 128-bit limbs (high bits dropped) *)
let split128 n v = List.init n (fun i -> Z.extract v (128 * i) 128)

let register reg =
  let get_square_root read insert c vm =
    let generator = read vm c "generator" and x = read vm c "x" and p = read vm c "p" in
    let success_x = is_quad_residue x p in
    let root_x = if success_x then Option.value (sqrt_prime_power x p) ~default:Z.zero else Z.zero in
    let gx = Z.mul generator x in
    let success_gx = is_quad_residue gx p in
    let root_gx = if success_gx then Option.value (sqrt_prime_power gx p) ~default:Z.zero else Z.zero in
    if Z.sign x <> 0 && success_x = success_gx then fail "assert success_x + success_gx ==1";
    set_val vm c "success_x" (of_bool success_x);
    set_val vm c "success_gx" (of_bool success_gx);
    insert vm c "sqrt_x" root_x;
    insert vm c "sqrt_gx" root_gx
  in
  reg C.uint384_get_square_root
    (get_square_root (fun vm c n -> pack128 vm c n 3) (fun vm c n v -> insert_limbs vm c n (split128 3 v)));
  reg C.uint256_get_square_root (get_square_root u256 insert_u256);
  reg C.uint384_div (fun c vm ->
      let b = pack128 vm c "b" 3 and p = pack128 vm c "p" 3 in
      nonzero b;
      let inv = mod_floor (mul_inv b p) p in
      insert_limbs vm c "b_inverse_mod_p" (split128 3 inv));
  (* uint384.rs, uint384_extension.rs *)
  reg C.uint384_unsigned_div_rem (fun c vm ->
      let a = pack128 vm c "a" 3 and d = pack128 vm c "div" 3 in
      nonzero d;
      let q, r = div_mod_floor a d in
      insert_limbs vm c "quotient" (split128 3 q);
      insert_limbs vm c "remainder" (split128 3 r));
  reg C.uint384_split_128 (fun c vm ->
      let a = get_z vm c "a" in
      set_int vm c "low" (Z.extract a 0 128);
      set_int vm c "high" (Z.shift_right a 128));
  reg C.add_no_uint384_check (fun c vm ->
      let aa = get_addr vm c "a" and ba = get_addr vm c "b" in
      let a i = z_at vm aa i and b i = z_at vm ba i in
      let shift = const_z c "SHIFT" in
      let carry s = if Z.geq s shift then Z.one else Z.zero in
      let c0 = carry (Z.add (a 0) (b 0)) in
      let c1 = carry (Z.add (Z.add (a 1) (b 1)) c0) in
      let c2 = carry (Z.add (Z.add (a 2) (b 2)) c1) in
      set_int vm c "carry_d0" c0;
      set_int vm c "carry_d1" c1;
      set_int vm c "carry_d2" c2);
  reg C.uint384_sqrt (fun c vm ->
      let a = pack128 vm c "a" 3 in
      let root = Z.sqrt a in
      if Z.sign root = 0 || Z.numbits root > 192 then fail "assert 0 <= root < 2 ** 192";
      insert_limbs vm c "root" (split128 3 root));
  reg C.sub_reduced_a_and_reduced_b (fun c vm ->
      let a = pack128 vm c "a" 3 and b = pack128 vm c "b" 3 and p = pack128 vm c "p" 3 in
      let res = if Z.gt a b then mod_floor (Z.sub a b) p else Z.sub p (mod_floor (Z.sub b a) p) in
      insert_limbs vm c "res" (split128 3 res));
  reg C.uint384_signed_nn (fun c vm ->
      let d2 = int_at vm (get_addr vm c "a") 2 in
      write_ap vm (of_bool (Felt.bits d2 <= 127)));
  let div_rem_768 c vm =
    let a = pack128 vm c "a" 6 and d = pack128 vm c "div" 3 in
    nonzero d;
    let q, r = div_mod_floor a d in
    insert_limbs vm c "quotient" (split128 6 q);
    insert_limbs vm c "remainder" (split128 3 r)
  in
  reg C.unsigned_div_rem_uint768_by_uint384 div_rem_768;
  reg C.unsigned_div_rem_uint768_by_uint384_stripped div_rem_768;

  (* vrf/ *)
  reg C.uint512_unsigned_div_rem (fun c vm ->
      let x = pack128 vm c "x" 4 and d = u256 vm c "div" in
      nonzero d;
      let q, r = div_mod_floor x d in
      insert_limbs vm c "quotient" (split128 4 q);
      insert_u256 vm c "remainder" r);
  reg C.inv_mod_p_uint256 (fun c vm ->
      let b = u256 vm c "b" and p = u256 vm c "p" in
      insert_u256 vm c "b_inverse_mod_p" (div_mod Z.one b p));
  reg C.inv_mod_p_uint512 (fun c vm ->
      let x = pack128 vm c "x" 4 and p = u256 vm c "p" in
      (* cairo-vm converts the inverse to a felt before splitting it *)
      let inv = Z.erem (div_mod Z.one x p) stark_p in
      insert_limbs vm c "x_inverse_mod_p" [ Z.extract inv 0 128; Z.shift_right inv 128 ])
