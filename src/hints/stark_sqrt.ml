(* p - 1 = q * 2^192, q odd. Recover the discrete logarithm of a^q
   in the 2-power subgroup eight bits at a time (Pohlig-Hellman).
   The inverse powers depend only on the field, and each run needs
   24 subgroup lookups instead of a fresh exponentiation for every bit. *)
let p = Felt.p
let q = Z.shift_right (Z.pred p) 192
let root_exponent = Z.shift_right (Z.succ q) 1
let radix = 256
let digits = 24
let mul a b = Z.erem (Z.mul a b) p
let next_power a = Z.powm a (Z.of_int radix) p

let tables = lazy (
    (* Three is a quadratic nonresidue modulo the Stark prime. *)
    let generator = Z.powm (Z.of_int 3) q p in
    let base = ref (Z.invert generator p) in
    let inverse = Array.init digits (fun _ ->
        let power = ref Z.one in
        let row = Array.init radix (fun _ -> let v = !power in power := mul v !base; v) in
        base := !power;
        row) in
    let top = inverse.(digits-1) and log = Hashtbl.create radix in
    for i = 0 to radix-1 do Hashtbl.add log top.((radix-i) mod radix) i done;
    inverse, log)

let sqrt value =
  let a = Z.erem value p in
  if Z.equal a Z.zero || Z.equal a Z.one then Some a else
  let inverse, log = Lazy.force tables in
  let powers = Array.make digits (Z.powm a q p) in
  for i = 1 to digits-1 do powers.(i) <- next_power powers.(i-1) done;
  let low = Hashtbl.find log powers.(digits-1) in
  if low land 1 <> 0 then None else begin
    let bits = Array.make digits low in
    for i = 1 to digits-1 do
      let order = digits-1-i in
      let residual = ref powers.(order) in
      for j = 0 to i-1 do residual := mul !residual inverse.(order+j).(bits.(j)) done;
      bits.(i) <- Hashtbl.find log !residual
    done;
    (* If a^q = g^e, then a^((q+1)/2) * g^(-e/2) squares to a. *)
    let result = ref (Z.powm a root_exponent p) in
    for i = 0 to digits-1 do
      let carry = if i+1 < digits then (bits.(i+1) land 1) lsl 7 else 0 in
      result := mul !result inverse.(i).((bits.(i) lsr 1) lor carry)
    done;
    Some (Z.min !result (Z.sub p !result))
  end
