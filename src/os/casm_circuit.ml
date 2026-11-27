(* Sierra circuit gates use four base-2^96 limbs. Inverse gates can produce
   a nullifier instead of an inverse. Only gates before that first failure
   are exposed as completed multiplication builtin instances. *)
open Errors
open Hintrt

let at p i = Vm.reloc_add_felt p (Felt.of_int i)

let value vm p =
  let rec read i result =
    if i < 0 then Some result else
      let cell = Vm.get vm (Felt.rseg p) (Felt.roff p + i) in
      if not (Felt.is_felt cell) then None
      else read (i-1) (Z.add (Z.shift_left result 96) (Felt.to_z cell)) in
  read 3 Z.zero

let assign vm ptr v =
  write_arg vm ptr (List.init 4 (fun i -> Felt.of_z (Z.extract v (96*i) 96)))

let compile ~arg ~ptr =
  let count_a = arg "n_add_mods" and count_m = arg "n_mul_mods" in
  let ptr_a = ptr "add_mod_builtin" and ptr_m = ptr "mul_mod_builtin" in
  fun vm ->
    let na = Felt.to_nat (count_a vm) and nm = Felt.to_nat (count_m vm) in
    let add = ptr_a vm and mul = ptr_m vm in
    if not (Felt.is_reloc add && Felt.is_reloc mul) then fail "Expected circuit builtin pointers";
    let modulus = match value vm mul with Some p when Z.sign p > 0 -> p | _ -> fail "Invalid circuit modulus" in
    let words = read_range vm mul 4 and values = mem_at vm mul 4 in
    let mo = mem_at vm mul 5 in
    let ao = if na = 0 then mo else mem_at vm add 5 in
    let gate offsets idx =
      let address i = Vm.reloc_add_felt values (mem_at vm offsets (3*idx+i)) in
      address 0, address 1, address 2 in
    let add_gate i =
      let a,b,c = gate ao i in
      match value vm a, value vm b with
      | Some x, Some y -> assign vm c (Z.erem (Z.add x y) modulus); true
      | None, Some y ->
          (match value vm c with None -> false | Some z -> assign vm a (Z.erem (Z.sub z y) modulus); true)
      | _ -> false in
    let mul_gate i =
      let a,b,c = gate mo i in
      match value vm a, value vm b with
      | Some x, Some y -> assign vm c (Z.erem (Z.mul x y) modulus); true
      | None, Some y ->
          let gcd = Z.gcd y modulus in
          let invertible = Z.equal gcd Z.one in
          assign vm a (if invertible then Z.invert y modulus else Z.div modulus gcd);
          invertible
      | _ -> fail "Missing circuit multiplication operand" in
    let ai = ref 0 and completed = ref nm in
    for mi = 0 to nm do
      while !ai < na && add_gate !ai do incr ai done;
      if mi < nm && not (mul_gate mi) && !completed = nm then completed := mi
    done;
    let fill p offsets count =
      for i = 0 to count-1 do
        write_arg vm (at p (7*i)) (words @ [values; at offsets (3*i); Felt.of_int (count-i)])
      done in
    fill add ao na; fill mul mo !completed
