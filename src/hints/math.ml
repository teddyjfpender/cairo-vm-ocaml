(* Felt comparisons, range assertions, splits, divisions and square roots
   (cairo-vm math_utils.rs, pow_utils.rs, garaga.rs and the nondet
   comparisons of poseidon_utils.rs). *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

let p_over_3 = Z.div Felt.p (z 3) and p_over_2 = Z.div Felt.p (z 2) and max_div = Z.div Felt.p rc_bound

let register reg =
  reg "from starkware.python.math_utils import log2_ceil\nids.res = log2_ceil(ids.value)"
    (fun c vm ->
      let value = get_z vm c "value" in
      check (Z.sign value > 0) "log2_ceil requires a positive integer";
      set_val vm c "res" (Felt.small (Z.numbits (Z.pred value))));
  (* assert_nn *)
  reg C.assert_nn (fun c vm ->
      let a = get_felt vm c "a" in
      if not (Felt.is_small a && a > Felt.empty) && Felt.bits a > 128 then
        fail "a = %s is out of range." (Z.to_string (Felt.to_z a)));
  (* assert_le_felt *)
  reg C.assert_le_felt (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      if Z.gt a b then fail "a = %s is not less than or equal to b = %s." (Z.to_string a) (Z.to_string b);
      let l = [ (a, 0); (Z.sub b a, 1); (Z.sub (Z.pred Felt.p) b, 2) ] in
      let l = List.sort compare l in
      let l0, _ = List.nth l 0 and l1, _ = List.nth l 1 and _, excluded = List.nth l 2 in
      check (Z.leq l0 p_over_3 && Z.leq l1 p_over_2) "assert_le_felt: arc check failed";
      set c.scopes "excluded" (Int (z excluded));
      let rc = get_ptr vm c "range_check_ptr" in
      let p3 = const_z c "PRIME_OVER_3_HIGH" and p2 = const_z c "PRIME_OVER_2_HIGH" in
      let q0, r0 = Z.ediv_rem l0 p3 and q1, r1 = Z.ediv_rem l1 p2 in
      let w k v = write_checked vm (Felt.rseg rc) (Felt.roff rc + k) (zf v) in
      w 1 q0;
      w 0 r0;
      w 3 q1;
      w 2 r1);
  reg C.assert_le_felt_excluded_0 (fun c vm -> write_ap vm (of_bool (not (Z.equal (var_z c.scopes "excluded") Z.zero))));
  reg C.assert_le_felt_excluded_1 (fun c vm -> write_ap vm (of_bool (not (Z.equal (var_z c.scopes "excluded") Z.one))));
  reg C.assert_le_felt_excluded_2 (fun c _ -> check (Z.equal (var_z c.scopes "excluded") (z 2)) "assert excluded == 2");
  (* unsigned_div_rem *)
  reg C.unsigned_div_rem (fun c vm ->
      let div = get_z vm c "div" and value = get_z vm c "value" in
      if Z.leq div Z.zero || Z.gt div max_div then fail "div=%s is out of the valid range." (Z.format "%x" div);
      let q, r = Z.ediv_rem value div in
      set_val vm c "q" (zf q);
      set_val vm c "r" (zf r));
  (* assert_lt_felt *)
  reg C.assert_lt_felt (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      if Z.geq a b then fail "a = %s is not less than b = %s." (Z.to_string a) (Z.to_string b));
  reg C.is_nn (fun c vm ->
      let a = get_felt vm c "a" in
      write_ap vm (of_bool (if Felt.is_small a then a < Felt.empty else Felt.bits a > 128)));
  reg C.is_nn_out_of_range (fun c vm ->
      write_ap vm (of_bool (Felt.bits (Felt.sub (Felt.neg (get_felt vm c "a")) Felt.one) > 128)));
  reg C.split_felt (fun c vm ->
      let low, high = Felt.split_at_limb ~two_limbs:true (get_felt vm c "value") in
      set_val vm c "low" low;
      set_val vm c "high" high);
  reg C.pow (fun c vm ->
      let e = get_member_z vm c "prev_locs" [ "exp" ] in
      set_member vm c "locs" [ "bit" ] (zf (Z.logand e Z.one)));
  reg C.assert_not_zero (fun c vm -> if Z.equal (get_z vm c "value") Z.zero then fail "assert_not_zero failed: 0 = 0.");
  reg C.is_le_felt (fun c vm -> write_ap vm (of_bool (Felt.compare (get_felt vm c "a") (get_felt vm c "b") > 0)));
  (* assert_not_equal *)
  reg C.assert_not_equal (fun c vm ->
      let a = get_val vm c "a" and b = get_val vm c "b" in
      let ok =
        (Felt.is_felt a && Felt.is_felt b) || (Felt.is_reloc a && Felt.is_reloc b && Felt.rseg a = Felt.rseg b)
      in
      if not ok then fail "assert_not_equal failed: non-comparable values";
      if Felt.equal a b then fail "assert_not_equal failed: %s = %s." (value_to_string a) (value_to_string b));
  (* assert_250_bit *)
  reg C.assert_250_bits (fun c vm ->
      let v = get_z vm c "value" in
      if Z.geq v (const_z c "UPPER_BOUND") then fail "%s is outside of the range [0, 2**250)." (Z.to_string v);
      let hi, lo = Z.ediv_rem v (const_z c "SHIFT") in
      set_val vm c "high" (zf hi);
      set_val vm c "low" (zf lo));
  reg C.is_positive (fun c vm ->
      let a = get_felt vm c "value" in
      let positive = if Felt.is_small a then Felt.small_val a > 0 else begin
        let v = as_int (Felt.to_z a) in
        if Z.geq (Z.abs v) rc_bound then fail "value=%s is out of the valid range." (Z.to_string v);
        Z.sign v > 0
      end in set_val vm c "is_positive" (of_bool positive));
  reg C.split_int_assert_range (fun c vm -> if not (Z.equal (get_z vm c "value") Z.zero) then fail "split_int(): value is out of range.");
  reg C.split_int (fun c vm ->
      let res = Z.erem (get_z vm c "value") (get_z vm c "base") in
      if Z.geq res (get_z vm c "bound") then fail "split_int(): Limb %s is out of range." (Z.to_string res);
      let o = get_ptr vm c "output" in
      write_checked vm (Felt.rseg o) (Felt.roff o) (zf res));
  (* signed_div_rem *)
  reg C.signed_div_rem (fun c vm ->
      let div = get_z vm c "div" in
      if Z.leq div Z.zero || Z.gt div max_div then fail "div=%s is out of the valid range." (Z.format "%x" div);
      let bound = get_z vm c "bound" in
      if Z.gt bound (Z.div rc_bound (z 2)) then fail "bound is out of the valid range.";
      let v = as_int (get_z vm c "value") in
      let q = Z.fdiv v div in
      let r = Z.sub v (Z.mul q div) in
      if Z.lt q (Z.neg bound) || Z.geq q bound then fail "signed_div_rem: quotient out of range";
      set_val vm c "r" (zf r);
      set_val vm c "biased_q" (zf (Z.add q bound)));
  let ptr_diff vm c =
    let d = value_sub (get_val vm c "elements_end") (get_val vm c "elements") in
    Felt.to_z d
  in
  reg C.nondet_elements_over_ten (fun c vm -> write_ap vm (of_bool (Z.geq (ptr_diff vm c) (z 10))));
  reg C.nondet_elements_over_two (fun c vm -> write_ap vm (of_bool (Z.geq (ptr_diff vm c) (z 2))));
  reg C.assert_le_felt_v_0_6 (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      if Z.gt a b then fail "a = %s is not less than or equal to b = %s." (Z.to_string a) (Z.to_string b));
  reg C.assert_le_felt_v_0_8 (fun c vm ->
      let a = get_felt vm c "a" and b = get_felt vm c "b" in
      if Felt.compare a b > 0 then
        fail "a = %s is not less than or equal to b = %s." (Felt.to_string a) (Felt.to_string b);
      if find_builtin vm Builtin.Range_check = None then fail "Expected range_check builtin to be present";
      let bound = Hintrt.rc_bound in
      let small_inputs = Z.lt (Felt.to_z a) bound && Z.lt (Felt.to_z (Felt.sub b a)) bound in
      set_val vm c "small_inputs" (of_bool small_inputs));
  reg C.is_250_bits (fun c vm ->
      set_val vm c "is_250" (of_bool (Felt.bits (get_felt vm c "addr") <= 250)));
  reg C.is_addr_bounded (fun c vm ->
      let addr = get_z vm c "addr" in
      let bound = const_full c "starkware.starknet.common.storage.ADDR_BOUND" in
      if not (Z.lt (two_pow 250) bound && Z.leq bound (two_pow 251) && Z.gt (Z.shift_left bound 1) Felt.p) then
        fail "normalize_address() cannot be used with the current constants.";
      set_val vm c "is_small" (of_bool (Z.lt addr bound)));
  reg C.sqrt (fun c vm ->
      let v = get_z vm c "value" in
      if Z.geq v (two_pow 250) then fail "Value: %s is outside valid range [0, 2**250)" (Z.to_string v);
      set_val vm c "root" (Felt.of_z (Z.sqrt v)));
  reg C.a_b_bitand_1 (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      set_val vm c "a_lsb" (Felt.of_z (Z.logand a Z.one));
      set_val vm c "b_lsb" (Felt.of_z (Z.logand b Z.one)));
  reg C.nondet_n_greater_than_10 (fun c vm -> write_ap vm (of_bool (Z.geq (get_z vm c "n") (z 10))));
  reg C.nondet_n_greater_than_2 (fun c vm -> write_ap vm (of_bool (Z.geq (get_z vm c "n") (z 2))));
  reg C.get_felt_bit_length (fun c vm -> set_val vm c "bit_length" (Felt.small (Felt.bits (get_felt vm c "x"))));
  (* math_utils.rs *)
  reg C.is_quad_residue (fun c vm ->
      let x = get_z vm c "x" in
      let y =
        if Z.sign x = 0 || Z.equal x Z.one then x
        else if Z.equal (Z.powm x Secp.felt_max_halved Felt.p) Z.one then Option.value (Secp.felt_sqrt x) ~default:Z.zero
        else
          let x3 = Z.erem (Z.mul x (Z.invert (z 3) Felt.p)) Felt.p in
          Option.value (Secp.felt_sqrt x3) ~default:Z.zero
      in
      set_int vm c "y" y);
  (* SPLIT_XX: square root modulo 2**255 - 19 (ed25519) *)
  reg C.split_xx (fun c vm ->
      let a = get_addr vm c "xx" in
      let xx = Z.add (z_at vm a 0) (Z.erem (Z.shift_left (z_at vm a 1) 128) Felt.p) in
      let p = Secp.secp_p_v2 in
      let ii = Z.of_string "19681161376707505956807079304988542015446066515923890162744021073123829784752" in
      let x = Z.powm xx (Z.fdiv (Z.add p (z 3)) (z 8)) p in
      (* BigUint subtraction: cairo-vm panics when x * x < xx *)
      if Z.lt (Z.mul x x) xx then fail "split_xx: attempt to subtract with overflow";
      let x = if Z.sign (Z.erem (Z.sub (Z.mul x x) xx) p) <> 0 then Z.erem (Z.mul x ii) p else x in
      let x = if Z.is_odd x then Z.sub p x else x in
      insert_limbs vm c "x" [ Z.extract x 0 128; Z.shift_right x 128 ])
