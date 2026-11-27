(* Uint256 / Uint128 arithmetic (cairo-vm uint256_utils.rs). *)

open Errors
open Hintrt
module C = Hint_codes

let read_uint256 vm c name =
  let low = get_member_z vm c name [ "low" ] in
  let high = get_member_z vm c name [ "high" ] in
  Z.add (Z.shift_left high 128) low

let write_uint256 vm c name value =
  set_member vm c name [ "low" ] (zf (Z.extract value 0 128));
  set_member vm c name [ "high" ] (zf (Z.shift_right value 128))

(* ---- uint256 at an address (cairo-vm Uint256::from_base_addr) ---- *)
let uint256_at vm addr off_low off_high = (z_at vm addr off_low, z_at vm addr off_high)
let pack256 (low, high) = Z.add (Z.shift_left high 128) low

let ge_felt v bound = Z.geq (Felt.to_z v) bound

let register reg =
  (* uint256_add *)
  reg C.uint256_add (fun c vm ->
      let shift = Option.value (const_opt c "SHIFT") ~default:rc_bound in
      let g n m = get_member_z vm c n [ m ] in
      let sum_low = Z.add (g "a" "low") (g "b" "low") in
      let carry_low = if Z.geq sum_low shift then Z.one else Z.zero in
      set_val vm c "carry_low" (zf carry_low);
      let sum_high = Z.add (Z.add (g "a" "high") (g "b" "high")) carry_low in
      set_val vm c "carry_high" (zf (if Z.geq sum_high shift then Z.one else Z.zero)));
  reg C.split_64 (fun c vm ->
      let low, high = Felt.split_at_limb ~two_limbs:false (get_felt vm c "a") in
      set_val vm c "low" low;
      set_val vm c "high" high);
  reg C.uint256_sqrt (fun c vm ->
      let n = Z.add (Z.shift_left (get_member_z vm c "n" [ "high" ]) 128) (get_member_z vm c "n" [ "low" ]) in
      let root = Z.sqrt n in
      check (Z.lt root (two_pow 128)) "uint256_sqrt: root out of range";
      set_member vm c "root" [ "low" ] (zf root);
      set_member vm c "root" [ "high" ] Felt.zero);
  reg C.uint256_signed_nn (fun c vm -> write_ap vm (of_bool (Z.lt (get_member_z vm c "a" [ "high" ]) (two_pow 127))));
  reg C.uint256_unsigned_div_rem (fun c vm ->
      let a = read_uint256 vm c "a" and d = read_uint256 vm c "div" in
      if Z.equal d Z.zero then fail "uint256_unsigned_div_rem: division by zero";
      let q, r = Z.ediv_rem a d in
      write_uint256 vm c "quotient" q;
      write_uint256 vm c "remainder" r);
  reg C.uint256_mul_div_mod (fun c vm ->
      let a = read_uint256 vm c "a" and b = read_uint256 vm c "b" in
      let d = read_uint256 vm c "div" in
      if Z.equal d Z.zero then fail "uint256_mul_div_mod: division by zero";
      let q, r = Z.ediv_rem (Z.mul a b) d in
      (* Rust's Uint512::split writes exactly four 128-bit quotient limbs. *)
      write_uint256 vm c "quotient_low" (Z.extract q 0 256);
      write_uint256 vm c "quotient_high" (Z.extract q 256 256);
      write_uint256 vm c "remainder" r);
  reg C.uint256_add_low (fun c vm ->
      let a = get_addr vm c "a" and b = get_addr vm c "b" in
      let al = mem_at vm a 0 and bl = mem_at vm b 0 in
      ignore (z_at vm a 1); ignore (z_at vm b 1);
      if not (Felt.is_felt al && Felt.is_felt bl) then fail "uint256_add: expected integers";
      set_val vm c "carry_low" (of_bool (ge_felt (Felt.add al bl) (two_pow 128))));
  reg C.uint128_add (fun c vm ->
      let a = get_felt vm c "a" and b = get_felt vm c "b" in
      set_val vm c "carry" (of_bool (ge_felt (Felt.add a b) (two_pow 128))));
  reg C.uint256_sub (fun c vm ->
      let a = pack256 (uint256_at vm (get_addr vm c "a") 0 1) in
      let b = pack256 (uint256_at vm (get_addr vm c "b") 0 1) in
      let m256 = two_pow 256 in
      let res =
        if Z.geq a b then Z.sub a b
        else if Z.geq m256 b then Z.add (Z.sub m256 b) a
        else
          let lb = Z.erem b m256 in
          if Z.geq a lb then Z.sub a lb else Z.add (Z.sub m256 lb) a
      in
      insert_u256 vm c "res" res);
  reg C.uint256_sqrt_felt (fun c vm ->
      let n = pack256 (uint256_at vm (get_addr vm c "n") 0 1) in
      let root = Z.sqrt n in
      if Z.numbits root > 128 then fail "assert 0 <= %s < 2 ** 128" (Z.to_string root);
      set_val vm c "root" (Felt.of_z root));
  reg C.uint256_expanded_unsigned_div_rem (fun c vm ->
      let a = pack256 (uint256_at vm (get_addr vm c "a") 0 1) in
      let d = pack256 (uint256_at vm (get_addr vm c "div") 1 3) in
      if Z.equal d Z.zero then fail "Attempted to divide by zero";
      let q, r = Z.ediv_rem a d in
      insert_u256 vm c "quotient" q;
      insert_u256 vm c "remainder" r)
