(* secp256k1 / secp256r1 / ed25519 field and curve hints, BigInt3 packing,
   signature recovery and the number theory they share (cairo-vm secp/,
   bigint.rs, ec_recover.rs).

   Each hint mirrors the cairo-vm v4.0.0 Rust implementation (the parity
   reference), including where it deviates from the Python hint text:
   - BigInt3/EcPoint/Uint384/... operands are read as consecutive limbs from
     the variable's address (get_relocatable_from_var_name), not by member name.
   - pack86 uses cairo-vm's signed_felt: values > (P-1)/2 are negative.
   - Floor division/modulo follow num-bigint's div_mod_floor/mod_floor. *)

open Errors
open Vm
open Hintrt
module C = Hint_codes
module F = Secp_field

(* ---- constants ---- *)

let stark_p = Felt.p
let secp_p = Z.of_string "115792089237316195423570985008687907853269984665640564039457584007908834671663"
let secp_p_v2 = Z.of_string "57896044618658097711785492504343953926634992332820282019728792003956564819949"
let alpha_v2 = Z.of_string "42204101795669822316448953119945047945709099015225996174933988943478124189485"
let secp_n = Z.of_string "115792089237316195423570985008687907852837564279074904382605163141518161494337"
let r1_p = Z.of_string "115792089210356248762697446949407573530086143415290314195533631308867097853951"
let r1_n = Z.of_string "115792089210356248762697446949407573529996955224135760342422259061068512044369"
let r1_alpha = Z.of_string "115792089210356248762697446949407573530086143415290314195533631308867097853948"
let r1_b = Z.of_string "0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B"
let base86 = two_pow 86

(* ---- num-bigint style integer arithmetic ---- *)

let nonzero d = if Z.sign d = 0 then fail "Attempted to divide by zero"
let div_floor a b = nonzero b; Z.fdiv a b
let mod_floor a b = nonzero b; Z.sub a (Z.mul (Z.fdiv a b) b)
let div_mod_floor a b = nonzero b; let q = Z.fdiv a b in (q, Z.sub a (Z.mul q b))

(* sympy's igcdex as ported by cairo-vm math_utils *)
let igcdex a b =
  if Z.sign a = 0 && Z.sign b = 0 then (Z.zero, Z.one, Z.zero)
  else if Z.sign a = 0 then (Z.zero, z (Z.sign b), Z.abs b)
  else if Z.sign b = 0 then (z (Z.sign a), Z.zero, Z.abs a)
  else begin
    let rec go a b x y r s =
      if Z.sign b = 0 then (x, y, a)
      else
        let q, c = div_mod_floor a b in
        go b c r s (Z.sub x (Z.mul q r)) (Z.sub y (Z.mul q s))
    in
    let x, y, g = go (Z.abs a) (Z.abs b) Z.one Z.zero Z.zero Z.one in
    (Z.mul x (z (Z.sign a)), Z.mul y (z (Z.sign b)), g)
  end

(* For p > 1 the igcdex coefficient is m's inverse, so GMP's gcdext gives
   the same result without a Zarith allocation per Euclid step. *)
let div_mod n m p =
  let not_invertible () = fail "div_mod: %s is not invertible modulo %s" (Z.to_string m) (Z.to_string p) in
  if Z.gt p Z.one then
    match Z.invert m p with inv -> Z.erem (Z.mul n inv) p | exception Division_by_zero -> not_invertible ()
  else begin
    let a, _, c = igcdex m p in
    if not (Z.equal c Z.one) then not_invertible ();
    mod_floor (Z.mul n a) p
  end

let mul_inv num_a p =
  if Z.sign num_a = 0 then Z.zero
  else begin
    let rec go a b x r =
      if Z.sign b = 0 then x
      else
        let q, c = div_mod_floor a b in
        go b c r (Z.sub x (Z.mul q r))
    in
    Z.mul (go (Z.abs num_a) (Z.abs p) Z.one Z.zero) (z (Z.sign num_a))
  end

let safe_div x y =
  if Z.sign y = 0 then fail "Attempted to divide by zero";
  let q, r = div_mod_floor x y in
  if Z.sign r <> 0 then fail "safe_div: %s is not divisible by %s" (Z.to_string x) (Z.to_string y);
  q

let ec_double_slope (x, y) alpha p = div_mod (Z.add (Z.mul (z 3) (Z.mul x x)) alpha) (Z.mul (z 2) y) p
let line_slope (x0, y0) (x1, y1) p = div_mod (Z.sub y0 y1) (Z.sub x0 x1) p

(* ---- square roots (math_utils::sqrt_prime_power, Felt252::sqrt) ---- *)

let is_prime p = Z.probab_prime p 25 > 0

(* math_utils::is_quad_residue *)
let is_quad_residue a p =
  if Z.sign p = 0 then fail "is_quad_residue: prime cannot be zero";
  let a = if Z.geq a p then mod_floor a p else a in
  if Z.lt a (z 2) || Z.lt p (z 3) then true
  else Z.equal (Z.powm a (Z.shift_right (Z.pred p) 1) p) Z.one

let legendre a p = if Z.sign a = 0 then 0 else if is_quad_residue a p then 1 else -1

(* Smaller of the two roots of a residue n modulo an odd prime. The root found
   does not depend on the chosen non-residue, so a deterministic search is
   equivalent to cairo-vm's seeded random one. *)
let tonelli_shanks n prime =
  if Z.sign n = 0 || Z.equal n Z.one then n
  else begin
    let pm1 = Z.pred prime in
    let s = Z.trailing_zeros pm1 in
    let t = Z.shift_right prime s in
    let a = Z.powm n t prime in
    let rec find d = if legendre d prime = -1 then d else find (Z.succ d) in
    let d = Z.powm (find (z 2)) t prime in
    let m = ref Z.zero and exponent = ref (Z.shift_left Z.one (s - 1)) in
    for i = 0 to s - 1 do
      let adm = Z.powm (Z.mul a (Z.powm d !m prime)) !exponent prime in
      exponent := Z.shift_right !exponent 1;
      if Z.equal adm pm1 then m := Z.add !m (Z.shift_left Z.one i)
    done;
    let root1 = Z.erem (Z.mul (Z.powm n (Z.shift_right (Z.succ t) 1) prime) (Z.powm d (Z.shift_right !m 1) prime)) prime in
    let root2 = Z.sub prime root1 in
    Z.min root1 root2
  end

let sqrt_prime_power a p =
  if Z.sign p = 0 || not (is_prime p) then None
  else begin
    let two = z 2 in
    let a = Z.erem a p in
    if Z.equal p two then Some a
    else if not (Z.lt a two || Z.equal (Z.powm a (Z.fdiv (Z.pred p) two) p) Z.one) then None
    else if Z.equal (Z.erem p (z 4)) (z 3) then begin
      let res = Z.powm a (Z.fdiv (Z.succ p) (z 4)) p in
      Some (Z.min res (Z.sub p res))
    end else begin
      let special =
        if Z.equal (Z.erem p (z 8)) (z 5) then begin
          let sign = Z.powm a (Z.fdiv (Z.pred p) (z 4)) p in
          if Z.equal sign Z.one then begin
            let res = Z.powm a (Z.fdiv (Z.add p (z 3)) (z 8)) p in
            Some (Z.min res (Z.sub p res))
          end else begin
            let b = Z.powm (Z.mul (z 4) a) (Z.fdiv (Z.sub p (z 5)) (z 8)) p in
            let x = Z.erem (Z.mul (Z.mul two a) b) p in
            if Z.equal (Z.powm x two p) a then Some x else None
          end
        end else None
      in
      match special with Some r -> Some r | None -> Some (tonelli_shanks a p)
    end
  end

let felt_max_halved = Z.shift_right (Z.pred stark_p) 1
let felt_sqrt = Stark_sqrt.sqrt

(* ---- memory access in cairo-vm's style ---- *)

let signed_at vm a i = Felt.to_signed_z (int_at vm a i)

let signed_for_prime prime v = if Z.gt v (Z.shift_right prime 1) then Z.sub v prime else v

let felts vm a off n = Array.init n (fun i -> int_at vm a (off + i))

(* BigInt3::pack86 of the limbs l.(o), l.(o + 1), l.(o + 2) *)
let pack86_l l o =
  let s i = Felt.to_signed_z l.(o + i) in
  Z.add (s 0) (Z.add (Z.shift_left (s 1) 86) (Z.shift_left (s 2) 172))

let pack86_at vm a off = pack86_l (felts vm a off 3) 0
let fpack m l o = F.pack m l.(o) l.(o + 1) l.(o + 2)

let pack86_for_prime_at prime vm a off =
  let l i = signed_for_prime prime (z_at vm a (off + i)) in
  Z.add (l 0) (Z.add (Z.shift_left (l 1) 86) (Z.shift_left (l 2) 172))

let pack86 vm c name = pack86_at vm (get_addr vm c name) 0

(* EcPoint {x: BigInt3, y: BigInt3} *)
let point vm c name =
  let a = get_addr vm c name in
  (pack86_at vm a 0, pack86_at vm a 3)

let point_for_prime prime vm c name =
  let a = get_addr vm c name in
  (pack86_for_prime_at prime vm a 0, pack86_for_prime_at prime vm a 3)

(* ---- scope variables ---- *)

let setz c n v = set c.scopes n (Int v)
let getz c n = var_z c.scopes n

(* ---- arithmetic modulo p ----
   A ring computes floor residues modulo p: on the C field kernel for p in
   (1, 2^256), otherwise on Zarith with cairo-vm's errors. *)

type 'a ring = {
  pack : Felt.t array -> int -> 'a; (* reduced BigInt3 at an offset *)
  of_num : dyn -> 'a; (* a [var_num] *)
  add : 'a -> 'a -> 'a;
  sub : 'a -> 'a -> 'a;
  mul : 'a -> 'a -> 'a;
  dyn : 'a -> dyn;
}

type ring_user = { run : 'a. 'a ring -> unit } [@@boxed]

let with_ring p u =
  match F.modulus p with
  | Some m ->
      u.run { pack = fpack m; of_num = (function Field v -> v | d -> F.of_z (Z.erem (num_z d) p));
              add = F.add m; sub = F.sub m; mul = F.mul m; dyn = (fun v -> Field v) }
  | None ->
      let md f a b = mod_floor (f a b) p in
      u.run { pack = (fun l o -> mod_floor (pack86_l l o) p); of_num = num_z;
              add = md Z.add; sub = md Z.sub; mul = md Z.mul; dyn = (fun v -> Int v) }

let set_all c r = List.iter (fun (n, v) -> set c.scopes n (r.dyn v))

(* [fast] on the field kernel, or the Zarith reference [slow] for other
   moduli and to raise cairo-vm's error when [fast] finds no inverse. *)
let field_or p fast slow = match Option.bind (F.modulus p) fast with Some v -> Field v | None -> Int (slow ())

let register reg =
  (* field_utils.rs *)
  let verify_zero c vm p =
    let l = felts vm (get_addr vm c "val") 0 3 in
    match Option.bind (F.modulus p) (fun m -> F.exact_quotient m l.(0) l.(1) l.(2)) with
    | Some q -> set_val vm c "q" q
    | None ->
        let v = pack86_l l 0 in
        let q, r = div_mod_floor v p in
        if Z.sign r <> 0 then fail "verify_zero: Invalid input %s" (Z.to_string v);
        set_int vm c "q" q
  in
  let verify_zero_fixed p c vm = setz c "SECP_P" p; verify_zero c vm p in
  reg C.verify_zero_v1 (verify_zero_fixed secp_p);
  reg C.verify_zero_v2 (verify_zero_fixed secp_p);
  reg C.verify_zero_v3 (verify_zero_fixed secp_p_v2);
  reg C.verify_zero_external_secp (fun c vm -> verify_zero c vm (getz c "SECP_P"));
  reg C.reduce_v1 (fun c vm ->
      setz c "SECP_P" secp_p;
      setz c "value" (mod_floor (pack86 vm c "x") secp_p));
  reg C.reduce_v2 (fun c vm ->
      let p = getz c "SECP_P" in
      setz c "value" (mod_floor (pack86 vm c "x") p));
  reg C.reduce_ed25519 (fun c vm ->
      setz c "value" (mod_floor (pack86 vm c "x") secp_p_v2);
      setz c "SECP_P" secp_p_v2);
  let is_zero_pack c vm =
    setz c "SECP_P" secp_p;
    setz c "x" (mod_floor (pack86 vm c "x") secp_p)
  in
  reg C.is_zero_pack_v1 is_zero_pack;
  reg C.is_zero_pack_v2 is_zero_pack;
  let is_zero_pack_external c vm =
    let p = getz c "SECP_P" in
    setz c "x" (mod_floor (pack86 vm c "x") p)
  in
  reg C.is_zero_pack_external_secp_v1 is_zero_pack_external;
  reg C.is_zero_pack_external_secp_v2 is_zero_pack_external;
  reg C.is_zero_pack_ed25519 (fun c vm ->
      setz c "x" (mod_floor (pack86 vm c "x") secp_p_v2);
      setz c "SECP_P" secp_p_v2);
  let is_zero_nondet c vm = write_ap vm (of_bool (Z.sign (getz c "x") = 0)) in
  reg C.is_zero_nondet is_zero_nondet;
  reg C.is_zero_int is_zero_nondet;
  reg C.is_zero_assign_scope_vars (fun c _ ->
      setz c "SECP_P" secp_p;
      let v = div_mod Z.one (getz c "x") secp_p in
      setz c "value" v;
      setz c "x_inv" v);
  reg C.is_zero_assign_scope_vars_external_secp (fun c _ ->
      let p = getz c "SECP_P" in
      let v = div_mod Z.one (getz c "x") p in
      setz c "value" v;
      setz c "x_inv" v);
  reg C.is_zero_assign_scope_vars_ed25519 (fun c _ ->
      let v = div_mod Z.one (getz c "x") secp_p_v2 in
      setz c "x_inv" v;
      setz c "value" v;
      setz c "SECP_P" secp_p_v2);

  (* bigint_utils.rs *)
  let nondet_bigint3 c vm =
    let res = get_addr vm c "res" in
    match var c.scopes "value" with
    | Field v -> write_arg vm res (List.init 3 (F.limb86 v))
    | _ ->
        let v = getz c "value" in
        if Z.sign v < 0 then fail "Couldn't convert BigInt to BigUint";
        if Z.numbits v > 258 then fail "Value %s is out of range for split" (Z.to_string v);
        write_arg vm res (List.map zf [ Z.extract v 0 86; Z.extract v 86 86; Z.extract v 172 86 ])
  in
  reg C.nondet_bigint3_v1 nondet_bigint3;
  reg C.nondet_bigint3_v2 nondet_bigint3;
  reg C.hi_max_bitlen (fun c vm ->
      let bu = Felt.bits (int_at vm (get_addr vm c "scalar_u") 2) in
      let bv = Felt.bits (int_at vm (get_addr vm c "scalar_v") 2) in
      let len_hi = max bu bv in
      set_int vm c "len_hi" (if len_hi = 0 then Z.pred stark_p else z (len_hi - 1)));

  (* secp/ec_utils.rs *)
  let ec_negate p c vm =
    let y = pack86_at vm (get_addr vm c "point") 3 in
    setz c "value" (mod_floor (Z.neg y) p);
    setz c "SECP_P" p
  in
  reg C.ec_negate (ec_negate secp_p);
  reg C.ec_negate_embedded_secp (ec_negate secp_p_v2);
  let doubling_slope name pack_prime p alpha =
    let alpha_f = F.of_z alpha in
    fun c vm ->
      setz c "SECP_P" p;
      let fast m =
        if pack_prime != stark_p then None
        else
          let l = felts vm (get_addr vm c name) 0 6 in
          let x = fpack m l 0 and y = fpack m l 3 in
          let x2 = F.mul m x x in
          F.div m (F.add m (F.add m x2 (F.add m x2 x2)) alpha_f) (F.add m y y)
      in
      let v = field_or p fast (fun () -> ec_double_slope (point_for_prime pack_prime vm c name) alpha p) in
      set c.scopes "value" v;
      set c.scopes "slope" v
  in
  reg C.ec_double_slope_v1 (doubling_slope "point" stark_p secp_p Z.zero);
  reg C.ec_double_slope_v2 (doubling_slope "point" stark_p secp_p_v2 alpha_v2);
  reg C.ec_double_slope_v3 (doubling_slope "pt" stark_p secp_p Z.zero);
  reg C.ec_double_slope_v4 (doubling_slope "point" r1_p r1_p r1_alpha);
  reg C.ec_double_slope_v5 (doubling_slope "point" stark_p r1_p r1_alpha);
  reg C.ec_double_slope_external_consts (fun c vm ->
      let pt = point vm c "point" in
      let p = getz c "SECP_P" and alpha = getz c "ALPHA" in
      let v = ec_double_slope pt alpha p in
      setz c "value" v;
      setz c "slope" v);
  let compute_slope n0 n1 pname c vm =
    let l0 = felts vm (get_addr vm c n0) 0 6 in
    let l1 = felts vm (get_addr vm c n1) 0 6 in
    let p = getz c pname in
    let fast m = F.div m (F.sub m (fpack m l0 3) (fpack m l1 3)) (F.sub m (fpack m l0 0) (fpack m l1 0)) in
    let v = field_or p fast (fun () -> line_slope (point vm c n0) (point vm c n1) p) in
    set c.scopes "value" v;
    set c.scopes "slope" v
  in
  let compute_slope_assign n0 n1 p c vm =
    setz c "SECP_P" p;
    compute_slope n0 n1 "SECP_P" c vm
  in
  reg C.compute_slope_v1 (compute_slope_assign "point0" "point1" secp_p);
  reg C.compute_slope_v2 (compute_slope_assign "point0" "point1" secp_p_v2);
  reg C.compute_slope_whitelist (compute_slope_assign "pt0" "pt1" secp_p);
  reg C.compute_slope_secp256r1_v1 (compute_slope "point0" "point1" "SECP_P");
  reg C.compute_slope_secp256r1_v2 (compute_slope "point0" "point1" "SECP256R1_P");
  reg C.import_secp256r1_p (fun c _ -> setz c "SECP_P" r1_p);
  reg C.import_secp256r1_alpha (fun c _ -> setz c "ALPHA" r1_alpha);
  reg C.import_secp256r1_n (fun c _ -> setz c "N" r1_n);
  reg C.square_slope_x_mod_p (fun c vm ->
      let p = getz c "SECP_P" in
      let x0, y0 = point vm c "point0" in
      let x1, _ = point vm c "point1" in
      let slope = pack86 vm c "slope" in
      let v = mod_floor (Z.sub (Z.sub (Z.mul slope slope) x0) x1) p in
      setz c "slope" slope;
      setz c "x0" x0;
      setz c "x1" x1;
      setz c "y0" y0;
      setz c "value" v;
      setz c "new_x" v);
  let double_assign_new_x p name c vm =
    setz c "SECP_P" p;
    let s = felts vm (get_addr vm c "slope") 0 3 in
    let pt = felts vm (get_addr vm c name) 0 6 in
    with_ring p { run = fun r ->
      let slope = r.pack s 0 and x = r.pack pt 0 and y = r.pack pt 3 in
      let v = r.sub (r.mul slope slope) (r.add x x) in
      set_all c r [ ("slope", slope); ("x", x); ("y", y); ("value", v); ("new_x", v) ] }
  in
  reg C.ec_double_assign_new_x_v1 (double_assign_new_x secp_p "point");
  reg C.ec_double_assign_new_x_v2 (fun c vm -> double_assign_new_x (getz c "SECP_P") "point" c vm);
  reg C.ec_double_assign_new_x_v3 (double_assign_new_x secp_p_v2 "point");
  reg C.ec_double_assign_new_x_v4 (double_assign_new_x secp_p "pt");
  let new_y x_name y_name c _ =
    let slope = var_num c.scopes "slope" in
    let x = var_num c.scopes x_name in
    let new_x = var_num c.scopes "new_x" in
    let y = var_num c.scopes y_name in
    with_ring (getz c "SECP_P") { run = fun r ->
      let v = r.sub (r.mul (r.of_num slope) (r.sub (r.of_num x) (r.of_num new_x))) (r.of_num y) in
      set_all c r [ ("value", v); ("new_y", v) ] }
  in
  reg C.ec_double_assign_new_y (new_y "x" "y");
  let fast_add_new_x p n0 n1 c vm =
    setz c "SECP_P" p;
    let s = felts vm (get_addr vm c "slope") 0 3 in
    let l0 = felts vm (get_addr vm c n0) 0 6 in
    let l1 = felts vm (get_addr vm c n1) 0 6 in
    with_ring p { run = fun r ->
      let slope = r.pack s 0 and x0 = r.pack l0 0 and x1 = r.pack l1 0 and y0 = r.pack l0 3 in
      let v = r.sub (r.sub (r.mul slope slope) x0) x1 in
      set_all c r [ ("slope", slope); ("x0", x0); ("x1", x1); ("y0", y0); ("value", v); ("new_x", v) ] }
  in
  reg C.fast_ec_add_assign_new_x (fast_add_new_x secp_p "point0" "point1");
  reg C.fast_ec_add_assign_new_x_v2 (fast_add_new_x secp_p_v2 "point0" "point1");
  reg C.fast_ec_add_assign_new_x_v3 (fast_add_new_x secp_p "pt0" "pt1");
  reg C.fast_ec_add_assign_new_y (new_y "x0" "y0");
  let n_pair_bits result pairs c vm =
    let sv = get_z vm c "scalar_v" and su = get_z vm c "scalar_u" in
    let mz = get_z vm c "m" in
    let m = if Z.fits_int mz && Z.lt mz (two_pow 32) then Z.to_int mz else 253 in
    if m >= 253 then set_val vm c result Felt.zero
    else begin
      if m + 1 < pairs then fail "n_pair_bits: m must be at least the number of pairs minus one";
      let bit x i = if m - i >= 0 && Z.testbit x (m - i) then 1 else 0 in
      let res = ref 0 in
      for i = 0 to pairs - 1 do
        res := (!res lsl 2) + (bit su i lor (bit sv i lsl 1))
      done;
      set_val vm c result (Felt.small !res)
    end
  in
  reg C.quad_bit (n_pair_bits "quad_bit" 2);
  reg C.di_bit (n_pair_bits "dibit" 1);

  (* secp/signature.rs *)
  let div_mod_n_packed n c vm =
    let a = pack86 vm c "a" and b = pack86 vm c "b" in
    let v = div_mod a b n in
    setz c "a" a;
    setz c "b" b;
    setz c "value" v;
    setz c "res" v
  in
  reg C.div_mod_n_packed_divmod_v1 (fun c vm ->
      setz c "N" secp_n;
      div_mod_n_packed secp_n c vm);
  reg C.div_mod_n_packed_divmod_external_n (fun c vm -> div_mod_n_packed (getz c "N") c vm);
  let div_mod_n_safe_div a_name b_name add c _ =
    let a = getz c a_name and b = getz c b_name and res = getz c "res" in
    let n = getz c "N" in
    setz c "value" (Z.add (safe_div (Z.sub (Z.mul res b) a) n) (z add))
  in
  reg C.div_mod_n_safe_div (div_mod_n_safe_div "a" "b" 0);
  reg C.div_mod_n_safe_div_plus_one (div_mod_n_safe_div "a" "b" 1);
  reg C.xs_safe_div (div_mod_n_safe_div "x" "s" 0);
  reg C.get_point_from_x (fun c vm ->
      setz c "SECP_P" secp_p;
      let beta = const_z c "BETA" in
      let x_cube = mod_floor (pack86 vm c "x_cube") secp_p in
      let y_square = mod_floor (Z.add x_cube beta) secp_p in
      setz c "y_square_int" y_square;
      let y = Z.powm y_square (Z.shift_right (Z.succ secp_p) 2) secp_p in
      setz c "y" y;
      let v = get_z vm c "v" in
      let y = if Z.is_even v <> Z.is_even y then Z.sub secp_p y else y in
      setz c "value" y);
  reg C.pack_modn_div_modn (fun c vm ->
      let x = mod_floor (pack86 vm c "x") secp_n in
      let s = mod_floor (pack86 vm c "s") secp_n in
      let v = div_mod x s secp_n in
      setz c "x" x;
      setz c "s" s;
      setz c "N" secp_n;
      setz c "value" v;
      setz c "res" v);

  (* bigint.rs *)
  reg C.bigint_pack_div_mod (fun c vm ->
      let p = pack86 vm c "P" in
      let xa = get_addr vm c "x" in
      let x =
        Z.add (pack86_at vm xa 0)
          (Z.add (Z.mul (signed_at vm xa 3) (Z.pow base86 3)) (Z.mul (signed_at vm xa 4) (Z.pow base86 4)))
      in
      let y = pack86 vm c "y" in
      let res = div_mod x y p in
      setz c "res" res;
      setz c "value" res;
      setz c "x" x;
      setz c "y" y;
      setz c "p" p);
  reg C.bigint_safe_div (fun c vm ->
      let res = getz c "res" and y = getz c "y" and x = getz c "x" and p = getz c "p" in
      let k = safe_div (Z.sub (Z.mul res y) x) p in
      let value, flag = if Z.sign k > 0 then (k, Felt.one) else (Z.neg k, Felt.zero) in
      setz c "k" k;
      setz c "value" value;
      set_val vm c "flag" flag);

  (* ec_recover.rs *)
  reg C.ec_recover_div_mod_n_packed (fun c vm ->
      let n = pack86 vm c "n" in
      nonzero n;
      let x = mod_floor (pack86 vm c "x") n in
      let s = mod_floor (pack86 vm c "s") n in
      let v = div_mod x s n in
      setz c "value" v;
      setz c "res" v);
  reg C.ec_recover_sub_a_b (fun c vm ->
      let a = pack86 vm c "a" and b = pack86 vm c "b" in
      let v = Z.sub a b in
      setz c "value" v;
      setz c "res" v);
  reg C.ec_recover_product_mod (fun c vm ->
      let a = pack86 vm c "a" and b = pack86 vm c "b" and m = pack86 vm c "m" in
      nonzero m;
      let product = Z.mul a b in
      let v = mod_floor product m in
      setz c "product" product;
      setz c "m" m;
      setz c "value" v;
      setz c "res" v);
  reg C.ec_recover_product_div_m (fun c _ ->
      let product = getz c "product" and m = getz c "m" in
      let v = div_floor product m in
      setz c "k" v;
      setz c "value" v);
  reg C.bigint_to_uint256 (fun c vm ->
      let d0 = get_member_z vm c "x" [ "d0" ] and d1 = get_member_z vm c "x" [ "d1" ] in
      set_val vm c "low" (zf (Z.logand (Z.add d0 (Z.mul d1 (const_z c "BASE"))) (mask 128))));
  reg C.ec_mul_inner (fun c vm -> write_ap vm (zf (Z.erem (get_z vm c "scalar") (z 2))))

(* cairo0_hints.rs: dispatched by cairo-vm only when built with the
   `cairo-0-secp-hints` feature, so they are not part of the default table. *)
let register_cairo0 reg =
  let reduce_into name c vm = setz c name (mod_floor (pack86 vm c "x") r1_p) in
  reg C.Cairo0.secp_reduce (reduce_into "value");
  reg C.Cairo0.secp_reduce_x (reduce_into "x");
  reg C.Cairo0.compute_q_mod_prime (fun c vm ->
      let v = pack86 vm c "val" in
      let q, r = div_mod_floor v r1_p in
      if Z.sign r <> 0 then fail "verify_zero: Invalid input %s" (Z.to_string v);
      set_int vm c "q" q);
  reg C.Cairo0.compute_ids_high_low (fun c vm ->
      setz c "SECP256R1_P" r1_p;
      let upper = const_z c "UPPER_BOUND" and shift = const_z c "SHIFT" in
      let value = get_z vm c "value" in
      if Z.gt value (Z.erem upper stark_p) then fail "Value %s is outside of the range" (Z.to_string value);
      let shift = Z.erem shift stark_p in
      nonzero shift;
      let high, low = Z.ediv_rem value shift in
      set_int vm c "high" high;
      set_int vm c "low" low);
  let r1_get_point_from_x pack_prime c vm =
    setz c "SECP256R1_P" r1_p;
    let a = get_addr vm c "x" in
    let x = pack86_for_prime_at pack_prime vm a 0 in
    let y_square = Z.rem (Z.add (Z.add (Z.powm x (z 3) r1_p) (Z.mul r1_alpha x)) r1_b) r1_p in
    setz c "y_square_int" y_square;
    let y = Z.powm y_square (Z.fdiv (Z.succ r1_p) (z 4)) r1_p in
    setz c "y" y;
    let v = get_z vm c "v" in
    setz c "value" (if Z.is_even v = Z.is_even y then y else mod_floor (Z.neg y) r1_p)
  in
  reg C.Cairo0.secp_r1_get_point_from_x (r1_get_point_from_x r1_p);
  reg C.Cairo0.secp_r1_get_point_from_x_v2 (r1_get_point_from_x stark_p);
  reg C.Cairo0.is_on_curve_2 (fun c vm ->
      let y = getz c "y" and y2 = getz c "y_square_int" in
      set_val vm c "is_on_curve" (of_bool (Z.equal (Z.rem (Z.mul y y) r1_p) y2)));
  let secp_double_assign_new_x pack_prime c vm =
    setz c "SECP256R1_P" r1_p;
    let slope = pack86_for_prime_at pack_prime vm (get_addr vm c "slope") 0 in
    let x, y = point_for_prime pack_prime vm c "point" in
    let v = mod_floor (Z.sub (Z.powm slope (z 2) r1_p) (Z.shift_left x 1)) r1_p in
    setz c "slope" slope;
    setz c "x" x;
    setz c "y" y;
    setz c "value" v;
    setz c "new_x" v
  in
  reg C.Cairo0.secp_double_assign_new_x (secp_double_assign_new_x r1_p);
  reg C.Cairo0.secp_double_assign_new_x_v2 (secp_double_assign_new_x stark_p);
  reg C.Cairo0.generate_nibbles (fun c vm ->
      let num = u256 vm c "scalar" in
      let nibbles = List.init 64 (fun i -> Felt.small (Z.to_int (Z.extract num (4 * i) 4))) in
      (* nibbles.pop() takes the last element; nibbles[0] the first *)
      let rev = List.rev nibbles in
      set_val vm c "first_nibble" (List.hd rev);
      let rest = List.rev (List.tl rev) in
      set_val vm c "last_nibble" (List.hd rest);
      set c.scopes "nibbles" (Values rest));
  reg C.Cairo0.fast_secp_add_assign_new_y (fun c _ ->
      let slope = getz c "slope" and x = getz c "x" and new_x = getz c "new_x" and y = getz c "y" in
      let v = mod_floor (Z.sub (Z.mul slope (Z.sub x new_x)) y) r1_p in
      setz c "value" v;
      setz c "new_y" v);
  reg C.Cairo0.write_nibbles_to_mem (fun c vm ->
      match var c.scopes "nibbles" with
      | Values l -> (
          match List.rev l with
          | last :: rest ->
              set c.scopes "nibbles" (Values (List.rev rest));
              write_checked vm 1 vm.fp last
          | [] -> fail "Nibbles list is empty")
      | _ -> fail "Variable nibbles is not a list");
  reg C.Cairo0.compute_value_div_mod (fun c _ -> setz c "value" (div_mod Z.one (getz c "x") r1_p))
