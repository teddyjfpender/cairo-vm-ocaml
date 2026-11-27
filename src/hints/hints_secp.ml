(* secp256k1 / secp256r1 / ed25519 / Stark-curve EC, bigint, uint384, uint512,
   vrf, garaga and field-arithmetic hints.

   Each hint mirrors the cairo-vm v4.0.0 Rust implementation (the parity
   reference), including where it deviates from the Python hint text:
   - BigInt3/EcPoint/Uint384/... operands are read as consecutive limbs from
     the variable's address (get_relocatable_from_var_name), not by member name.
   - pack86 uses cairo-vm's signed_felt: values > (P-1)/2 are negative.
   - Floor division/modulo follow num-bigint's div_mod_floor/mod_floor.
   Several codes already implemented in Hints are re-registered here so that
   the shared scope variables (SECP_P, N, ...) are set and read exactly as in
   Rust; Hints_registry runs [register] after Hints is initialized, so these
   definitions take precedence. *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

let reg = Hints.reg
let z = Z.of_int
let two_pow n = Z.shift_left Z.one n
let mask n = Z.pred (two_pow n)
let check b msg = if not b then fail "%s" msg

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

let div_mod n m p =
  let a, _, c = igcdex m p in
  if not (Z.equal c Z.one) then fail "div_mod: %s is not invertible modulo %s" (Z.to_string m) (Z.to_string p);
  mod_floor (Z.mul n a) p

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

let powm b e m = if Z.sign m = 0 then fail "Attempted to divide by zero" else Z.powm b e m

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

(* Felt252::sqrt: the smaller root, or None for a non-residue *)
let felt_sqrt a =
  let a = Z.erem a stark_p in
  if Z.sign a = 0 then Some Z.zero
  else if not (Z.equal (Z.powm a (Z.shift_right (Z.pred stark_p) 1) stark_p) Z.one) then None
  else Some (tonelli_shanks a stark_p)

(* ---- SHA-256 (for random_ec_point) ---- *)

let sha256 (msg : string) : string =
  let k =
    [| 0x428a2f98; 0x71374491; 0xb5c0fbcf; 0xe9b5dba5; 0x3956c25b; 0x59f111f1; 0x923f82a4; 0xab1c5ed5;
       0xd807aa98; 0x12835b01; 0x243185be; 0x550c7dc3; 0x72be5d74; 0x80deb1fe; 0x9bdc06a7; 0xc19bf174;
       0xe49b69c1; 0xefbe4786; 0x0fc19dc6; 0x240ca1cc; 0x2de92c6f; 0x4a7484aa; 0x5cb0a9dc; 0x76f988da;
       0x983e5152; 0xa831c66d; 0xb00327c8; 0xbf597fc7; 0xc6e00bf3; 0xd5a79147; 0x06ca6351; 0x14292967;
       0x27b70a85; 0x2e1b2138; 0x4d2c6dfc; 0x53380d13; 0x650a7354; 0x766a0abb; 0x81c2c92e; 0x92722c85;
       0xa2bfe8a1; 0xa81a664b; 0xc24b8b70; 0xc76c51a3; 0xd192e819; 0xd6990624; 0xf40e3585; 0x106aa070;
       0x19a4c116; 0x1e376c08; 0x2748774c; 0x34b0bcb5; 0x391c0cb3; 0x4ed8aa4a; 0x5b9cca4f; 0x682e6ff3;
       0x748f82ee; 0x78a5636f; 0x84c87814; 0x8cc70208; 0x90befffa; 0xa4506ceb; 0xbef9a3f7; 0xc67178f2 |]
  in
  let m32 = 0xFFFFFFFF in
  let rotr x n = ((x lsr n) lor (x lsl (32 - n))) land m32 in
  let h = [| 0x6a09e667; 0xbb67ae85; 0x3c6ef372; 0xa54ff53a; 0x510e527f; 0x9b05688c; 0x1f83d9ab; 0x5be0cd19 |] in
  let len = String.length msg in
  let padded_len = ((len + 9 + 63) / 64) * 64 in
  let b = Bytes.make padded_len '\000' in
  Bytes.blit_string msg 0 b 0 len;
  Bytes.set b len '\x80';
  Bytes.set_int64_be b (padded_len - 8) (Int64.of_int (len * 8));
  let w = Array.make 64 0 in
  for blk = 0 to (padded_len / 64) - 1 do
    for i = 0 to 15 do
      w.(i) <- Int32.to_int (Bytes.get_int32_be b ((blk * 64) + (4 * i))) land m32
    done;
    for i = 16 to 63 do
      let s0 = rotr w.(i - 15) 7 lxor rotr w.(i - 15) 18 lxor (w.(i - 15) lsr 3) in
      let s1 = rotr w.(i - 2) 17 lxor rotr w.(i - 2) 19 lxor (w.(i - 2) lsr 10) in
      w.(i) <- (w.(i - 16) + s0 + w.(i - 7) + s1) land m32
    done;
    let a = ref h.(0) and bb = ref h.(1) and c = ref h.(2) and d = ref h.(3) in
    let e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
    for i = 0 to 63 do
      let s1 = rotr !e 6 lxor rotr !e 11 lxor rotr !e 25 in
      let ch = (!e land !f) lxor (lnot !e land m32 land !g) in
      let t1 = (!hh + s1 + ch + k.(i) + w.(i)) land m32 in
      let s0 = rotr !a 2 lxor rotr !a 13 lxor rotr !a 22 in
      let maj = (!a land !bb) lxor (!a land !c) lxor (!bb land !c) in
      let t2 = (s0 + maj) land m32 in
      hh := !g; g := !f; f := !e;
      e := (!d + t1) land m32;
      d := !c; c := !bb; bb := !a;
      a := (t1 + t2) land m32
    done;
    List.iteri (fun i v -> h.(i) <- (h.(i) + v) land m32) [ !a; !bb; !c; !d; !e; !f; !g; !hh ]
  done;
  let out = Bytes.create 32 in
  Array.iteri (fun i v -> Bytes.set_int32_be out (4 * i) (Int32.of_int v)) h;
  Bytes.to_string out

let z_of_be (s : string) =
  let r = ref Z.zero in
  String.iter (fun ch -> r := Z.add (Z.shift_left !r 8) (z (Char.code ch))) s;
  !r

(* 32-byte big-endian encoding of a field element (Felt252::to_bytes_be) *)
let be32 v =
  let b = Bytes.make 32 '\000' in
  let rec fill i v = if i >= 0 && Z.sign v > 0 then (Bytes.set b i (Char.chr (Z.to_int (Z.extract v 0 8))); fill (i - 1) (Z.shift_right v 8)) in
  fill 31 v;
  Bytes.to_string b

(* ---- memory access in cairo-vm's style ---- *)

let addr vm c name = get_addr vm c name

let int_at vm a i =
  let v = mem_at vm a i in
  if not (Felt.is_felt v) then fail "Expected integer at %d:%d" (Felt.rseg a) (Felt.roff a + i);
  v

let z_at vm a i = Felt.to_z (int_at vm a i)
let signed_at vm a i = Felt.to_signed_z (int_at vm a i)

let signed_for_prime prime v = if Z.gt v (Z.shift_right prime 1) then Z.sub v prime else v

(* BigInt3::pack86 of the limbs at a + off *)
let pack86_at vm a off =
  Z.add (signed_at vm a off) (Z.add (Z.shift_left (signed_at vm a (off + 1)) 86) (Z.shift_left (signed_at vm a (off + 2)) 172))

let pack86_for_prime_at prime vm a off =
  let l i = signed_for_prime prime (z_at vm a (off + i)) in
  Z.add (l 0) (Z.add (Z.shift_left (l 1) 86) (Z.shift_left (l 2) 172))

let pack86 vm c name = pack86_at vm (addr vm c name) 0

(* EcPoint {x: BigInt3, y: BigInt3} *)
let point vm c name =
  let a = addr vm c name in
  (pack86_at vm a 0, pack86_at vm a 3)

let point_for_prime prime vm c name =
  let a = addr vm c name in
  (pack86_for_prime_at prime vm a 0, pack86_for_prime_at prime vm a 3)

(* BigIntN::pack: unsigned 128-bit limbs *)
let pack128 vm c name n =
  let a = addr vm c name in
  let r = ref Z.zero in
  for i = n - 1 downto 0 do
    r := Z.add (Z.shift_left !r 128) (z_at vm a i)
  done;
  !r

(* BigIntN::split: n masked 128-bit limbs (high bits dropped) *)
let split128 n v = List.init n (fun i -> Z.extract v (128 * i) 128)

let insert_limbs vm c name vals = write_arg vm (addr vm c name) (List.map zf vals)

(* Uint256 {low, high} *)
let u256 vm c name =
  let a = addr vm c name in
  Z.add (Z.shift_left (z_at vm a 1) 128) (z_at vm a 0)

(* Uint256::split: masked low, unmasked high *)
let insert_u256 vm c name v = insert_limbs vm c name [ Z.logand v (mask 128); Z.shift_right v 128 ]

let set_int vm c name v = set_val vm c name (zf v)
let felt_z vm c name = Felt.to_z (get_felt vm c name)

(* ---- scope variables ---- *)

let setz c n v = set c.scopes n (Int v)
let getz c n = var_z c.scopes n

(* ---- Stark curve helpers (ec_utils.rs) ---- *)

let stark_beta = Z.of_string "3141592653589793238462643383279502884197169399375105820974944592307816406665"
let felt_max_halved = Z.shift_right (Z.pred stark_p) 1

let recover_y x =
  let y2 = Z.add (Z.add (Z.powm x (z 3) stark_p) x) stark_beta in
  let residue = Z.sign y2 = 0 || Z.equal y2 Z.one || Z.equal (Z.powm y2 felt_max_halved stark_p) Z.one in
  if residue then felt_sqrt y2 else None

let random_ec_point_seeded seed_bytes =
  let seed = sha256 seed_bytes in
  let rest = String.sub seed 1 31 in
  let y_neg = Char.code seed.[0] land 1 = 1 in
  let rec go i =
    if i >= 100 then fail "Random ec point not on curve"
    else begin
      let input = rest ^ String.make 1 (Char.chr i) ^ String.make 9 '\000' in
      let x = z_of_be (sha256 input) in
      match recover_y x with
      | Some y -> (zf x, zf (if y_neg then Z.neg y else y))
      | None -> go (i + 1)
    end
  in
  go 0

let stark_point vm c name =
  let a = addr vm c name in
  (int_at vm a 0, int_at vm a 1)

let write_point vm c name (x, y) =
  let a = addr vm c name in
  write_checked vm (Felt.rseg a) (Felt.roff a) x;
  write_checked vm (Felt.rseg a) (Felt.roff a + 1) y

(* ---- hints ---- *)

let register () =
  (* field_utils.rs *)
  let verify_zero c vm p =
    let v = pack86 vm c "val" in
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
    let res = addr vm c "res" in
    let v = getz c "value" in
    if Z.sign v < 0 then fail "Couldn't convert BigInt to BigUint";
    if Z.numbits v > 258 then fail "Value %s is out of range for split" (Z.to_string v);
    write_arg vm res (List.map zf [ Z.extract v 0 86; Z.extract v 86 86; Z.extract v 172 86 ])
  in
  reg C.nondet_bigint3_v1 nondet_bigint3;
  reg C.nondet_bigint3_v2 nondet_bigint3;
  reg C.hi_max_bitlen (fun c vm ->
      let bu = Felt.bits (int_at vm (addr vm c "scalar_u") 2) in
      let bv = Felt.bits (int_at vm (addr vm c "scalar_v") 2) in
      let len_hi = max bu bv in
      set_int vm c "len_hi" (if len_hi = 0 then Z.pred stark_p else z (len_hi - 1)));

  (* secp/ec_utils.rs *)
  let ec_negate p c vm =
    let y = pack86_at vm (addr vm c "point") 3 in
    setz c "value" (mod_floor (Z.neg y) p);
    setz c "SECP_P" p
  in
  reg C.ec_negate (ec_negate secp_p);
  reg C.ec_negate_embedded_secp (ec_negate secp_p_v2);
  let doubling_slope name pack_prime p alpha c vm =
    setz c "SECP_P" p;
    let pt = point_for_prime pack_prime vm c name in
    let v = ec_double_slope pt alpha p in
    setz c "value" v;
    setz c "slope" v
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
    let p0 = point vm c n0 in
    let p1 = point vm c n1 in
    let p = getz c pname in
    let v = line_slope p0 p1 p in
    setz c "value" v;
    setz c "slope" v
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
    let slope = pack86 vm c "slope" in
    let x, y = point vm c name in
    let slope = mod_floor slope p and x = mod_floor x p and y = mod_floor y p in
    let v = mod_floor (Z.sub (Z.mul slope slope) (Z.shift_left x 1)) p in
    setz c "slope" slope;
    setz c "x" x;
    setz c "y" y;
    setz c "value" v;
    setz c "new_x" v
  in
  reg C.ec_double_assign_new_x_v1 (double_assign_new_x secp_p "point");
  reg C.ec_double_assign_new_x_v2 (fun c vm -> double_assign_new_x (getz c "SECP_P") "point" c vm);
  reg C.ec_double_assign_new_x_v3 (double_assign_new_x secp_p_v2 "point");
  reg C.ec_double_assign_new_x_v4 (double_assign_new_x secp_p "pt");
  reg C.ec_double_assign_new_y (fun c _ ->
      let slope = getz c "slope" and x = getz c "x" and new_x = getz c "new_x" and y = getz c "y" in
      let p = getz c "SECP_P" in
      let v = mod_floor (Z.sub (Z.mul slope (Z.sub x new_x)) y) p in
      setz c "value" v;
      setz c "new_y" v);
  let fast_add_new_x p n0 n1 c vm =
    setz c "SECP_P" p;
    let slope = pack86 vm c "slope" in
    let x0, y0 = point vm c n0 in
    let x1, _ = point vm c n1 in
    let slope = mod_floor slope p and x0 = mod_floor x0 p and x1 = mod_floor x1 p and y0 = mod_floor y0 p in
    let v = mod_floor (Z.sub (Z.sub (Z.mul slope slope) x0) x1) p in
    setz c "slope" slope;
    setz c "x0" x0;
    setz c "x1" x1;
    setz c "y0" y0;
    setz c "value" v;
    setz c "new_x" v
  in
  reg C.fast_ec_add_assign_new_x (fast_add_new_x secp_p "point0" "point1");
  reg C.fast_ec_add_assign_new_x_v2 (fast_add_new_x secp_p_v2 "point0" "point1");
  reg C.fast_ec_add_assign_new_x_v3 (fast_add_new_x secp_p "pt0" "pt1");
  reg C.fast_ec_add_assign_new_y (fun c _ ->
      let slope = getz c "slope" and x0 = getz c "x0" and new_x = getz c "new_x" and y0 = getz c "y0" in
      let p = getz c "SECP_P" in
      let v = mod_floor (Z.sub (Z.mul slope (Z.sub x0 new_x)) y0) p in
      setz c "value" v;
      setz c "new_y" v);
  let n_pair_bits result pairs c vm =
    let sv = felt_z vm c "scalar_v" and su = felt_z vm c "scalar_u" in
    let mz = felt_z vm c "m" in
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
      let v = felt_z vm c "v" in
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
      let xa = addr vm c "x" in
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

  (* ec_utils.rs (Stark curve) *)
  reg C.random_ec_point (fun c vm ->
      let px, py = stark_point vm c "p" in
      let qx, qy = stark_point vm c "q" in
      let m = get_felt vm c "m" in
      let seed = String.concat "" (List.map (fun v -> be32 (Felt.to_z v)) [ px; py; m; qx; qy ]) in
      write_point vm c "s" (random_ec_point_seeded seed));
  reg C.chained_ec_op_random_ec_point (fun c vm ->
      let n = felt_z vm c "len" in
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
      let a = addr vm c "p" in
      write_checked vm (Felt.rseg a) (Felt.roff a) x;
      match recover_y (Felt.to_z x) with
      | Some y -> write_checked vm (Felt.rseg a) (Felt.roff a + 1) (zf y)
      | None -> fail "Point (%s, ?) is not on the curve" (Felt.to_string x));

  (* field_arithmetic.rs *)
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

  (* garaga.rs *)
  reg C.get_felt_bit_length (fun c vm -> set_val vm c "bit_length" (Felt.small (Felt.bits (get_felt vm c "x"))));

  (* uint384.rs, uint384_extension.rs *)
  reg C.uint384_unsigned_div_rem (fun c vm ->
      let a = pack128 vm c "a" 3 and d = pack128 vm c "div" 3 in
      nonzero d;
      let q, r = div_mod_floor a d in
      insert_limbs vm c "quotient" (split128 3 q);
      insert_limbs vm c "remainder" (split128 3 r));
  reg C.uint384_split_128 (fun c vm ->
      let a = felt_z vm c "a" in
      set_int vm c "low" (Z.extract a 0 128);
      set_int vm c "high" (Z.shift_right a 128));
  reg C.add_no_uint384_check (fun c vm ->
      let aa = addr vm c "a" and ba = addr vm c "b" in
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
      let d2 = int_at vm (addr vm c "a") 2 in
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
      insert_limbs vm c "x_inverse_mod_p" [ Z.extract inv 0 128; Z.shift_right inv 128 ]);

  (* math_utils.rs *)
  reg C.is_quad_residue (fun c vm ->
      let x = felt_z vm c "x" in
      let y =
        if Z.sign x = 0 || Z.equal x Z.one then x
        else if Z.equal (Z.powm x felt_max_halved stark_p) Z.one then Option.value (felt_sqrt x) ~default:Z.zero
        else
          let x3 = Z.erem (Z.mul x (Z.invert (z 3) stark_p)) stark_p in
          Option.value (felt_sqrt x3) ~default:Z.zero
      in
      set_int vm c "y" y);
  (* SPLIT_XX: square root modulo 2**255 - 19 (ed25519) *)
  reg C.split_xx (fun c vm ->
      let a = addr vm c "xx" in
      let xx = Z.add (z_at vm a 0) (Z.erem (Z.shift_left (z_at vm a 1) 128) stark_p) in
      let p = secp_p_v2 in
      let ii = Z.of_string "19681161376707505956807079304988542015446066515923890162744021073123829784752" in
      let x = Z.powm xx (Z.fdiv (Z.add p (z 3)) (z 8)) p in
      (* BigUint subtraction: cairo-vm panics when x * x < xx *)
      if Z.lt (Z.mul x x) xx then fail "split_xx: attempt to subtract with overflow";
      let x = if Z.sign (Z.erem (Z.sub (Z.mul x x) xx) p) <> 0 then Z.erem (Z.mul x ii) p else x in
      let x = if Z.is_odd x then Z.sub p x else x in
      insert_limbs vm c "x" [ Z.extract x 0 128; Z.shift_right x 128 ])

(* cairo0_hints.rs: dispatched by cairo-vm only when built with the
   `cairo-0-secp-hints` feature, so they are not part of the default table. *)
let register_cairo0_secp () =
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
      let value = felt_z vm c "value" in
      if Z.gt value (Z.erem upper stark_p) then fail "Value %s is outside of the range" (Z.to_string value);
      let shift = Z.erem shift stark_p in
      nonzero shift;
      let high, low = Z.ediv_rem value shift in
      set_int vm c "high" high;
      set_int vm c "low" low);
  let r1_get_point_from_x pack_prime c vm =
    setz c "SECP256R1_P" r1_p;
    let a = addr vm c "x" in
    let x = pack86_for_prime_at pack_prime vm a 0 in
    let y_square = Z.rem (Z.add (Z.add (Z.powm x (z 3) r1_p) (Z.mul r1_alpha x)) r1_b) r1_p in
    setz c "y_square_int" y_square;
    let y = Z.powm y_square (Z.fdiv (Z.succ r1_p) (z 4)) r1_p in
    setz c "y" y;
    let v = felt_z vm c "v" in
    setz c "value" (if Z.is_even v = Z.is_even y then y else mod_floor (Z.neg y) r1_p)
  in
  reg C.Cairo0.secp_r1_get_point_from_x (r1_get_point_from_x r1_p);
  reg C.Cairo0.secp_r1_get_point_from_x_v2 (r1_get_point_from_x stark_p);
  reg C.Cairo0.is_on_curve_2 (fun c vm ->
      let y = getz c "y" and y2 = getz c "y_square_int" in
      set_val vm c "is_on_curve" (of_bool (Z.equal (Z.rem (Z.mul y y) r1_p) y2)));
  let secp_double_assign_new_x pack_prime c vm =
    setz c "SECP256R1_P" r1_p;
    let slope = pack86_for_prime_at pack_prime vm (addr vm c "slope") 0 in
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

(* Runtime counterpart of cairo-vm's `cairo-0-secp-hints` cargo feature
   (off by default, as in the reference CLI build). *)
let register () =
  register ();
  if Sys.getenv_opt "CAIRO_VM_CAIRO0_SECP_HINTS" = Some "1" then register_cairo0_secp ()
