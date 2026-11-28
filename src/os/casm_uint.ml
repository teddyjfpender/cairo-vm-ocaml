(* Unsigned multilimbed CASM hint arithmetic with 128-bit little-endian limbs. *)
open Errors

let reader arg prefix count =
  let get = Array.init count (fun i -> arg (prefix ^ string_of_int i)) in
  fun vm -> Array.fold_right (fun read high ->
      let v = read vm in
      if not (Felt.is_felt v) then fail "Expected CASM integer limb";
      Z.add (Felt.to_z v) (Z.shift_left high 128)) get Z.zero

let writer put names =
  let setters = List.map put names in
  fun vm value ->
    let rec assign value = function
      | [] -> ()
      | [set] -> set vm (Felt.of_z value)
      | set :: rest -> set vm (Felt.of_z (Z.extract value 0 128)); assign (Z.shift_right value 128) rest in
    assign value setters

let division ~arg ~put count =
  let dividend = reader arg "dividend" count and divisor = reader arg "divisor" 2 in
  let quotient = writer put (List.init count (fun i -> "quotient" ^ string_of_int i)) in
  let remainder = writer put ["remainder0"; "remainder1"] in
  fun vm ->
    let divisor = divisor vm in
    if Z.equal divisor Z.zero then fail "CASM division by zero";
    let q,r = Z.ediv_rem (dividend vm) divisor in
    quotient vm q; remainder vm r

let square_root ~arg ~put =
  let low = arg "value_low" and high = arg "value_high" in
  let sqrt0 = put "sqrt0" and sqrt1 = put "sqrt1" in
  let remainder = writer put ["remainder_low"; "remainder_high"] in
  let flag = put "sqrt_mul_2_minus_remainder_ge_u128" in
  let two128 = Z.shift_left Z.one 128 in
  fun vm ->
    let value = Z.add (Felt.to_z (low vm)) (Z.shift_left (Felt.to_z (high vm)) 128) in
    let root, rem = Z.sqrt_rem value in
    sqrt0 vm (Felt.of_z (Z.extract root 0 64));
    sqrt1 vm (Felt.of_z (Z.shift_right root 64));
    remainder vm rem;
    flag vm (Hintrt.of_bool (Z.geq (Z.sub (Z.shift_left root 1) rem) two128))

let inverse ~arg ~put =
  let b = reader arg "b" 2 and n = reader arg "n" 2 in
  let s = writer put ["s_or_r0"; "s_or_r1"] and t = writer put ["t_or_k0"; "t_or_k1"] in
  let g = writer put ["g0_or_no_inv"; "g1_option"] and valid = put "g0_or_no_inv" in
  fun vm ->
    let b = b vm and n = n vm in
    let gcd = Z.gcd b n in
    if Z.equal n Z.one then (s vm b; t vm Z.one; g vm Z.one)
    else if not (Z.equal gcd Z.one) then begin
      let d = if Z.is_even gcd then Z.of_int 2 else gcd in
      s vm (Z.div b d); t vm (Z.div n d); g vm d
    end else begin
      if Z.equal n Z.zero then fail "CASM inverse modulo zero";
      let r = Z.invert b n in
      s vm r; t vm (Z.div (Z.pred (Z.mul r b)) n); valid vm Felt.zero
    end
