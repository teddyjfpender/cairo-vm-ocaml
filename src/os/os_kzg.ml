(* The sequencer commits to DA polynomial coefficients on BLS12-381 G1.
   Its public setup includes the monomial basis, so a multiscalar product
   gives the same commitment as evaluating the polynomial on the FFT domain
   and committing in the Lagrange basis. All inputs are public. *)
open Errors

let p = Z.of_string "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
let modulo x = Z.erem x p
let add x y = modulo (Z.add x y)
let sub x y = modulo (Z.sub x y)
let mul x y = modulo (Z.mul x y)
let square x = mul x x
let twice x = add x x
let half = Z.shift_right p 1
let sqrt_exp = Z.shift_right (Z.succ p) 2

let points = Array.init 4096 (fun i -> lazy (
    let data = String.sub Kzg_setup.points (48*i) 48 in
    let encoded = Hintrt.z_of_be data in
    let x = Z.extract encoded 0 381 in
    let rhs = add (mul x (square x)) (Z.of_int 4) in
    let y = Z.powm rhs sqrt_exp p in
    if not (Z.equal (square y) rhs) then fail "Invalid BLS12-381 setup point";
    x, if Z.gt y half = Z.testbit encoded 381 then y else Z.sub p y))

type point = Infinity | Jacobian of Z.t * Z.t * Z.t

let double = function
  | Infinity -> Infinity
  | Jacobian (x,y,z) ->
      let yy = square y and xx = square x in
      let s = twice (twice (mul x yy)) and m = add xx (twice xx) in
      let x' = sub (square m) (twice s) in
      let y' = sub (mul m (sub s x')) (twice (twice (twice (square yy)))) in
      Jacobian (x', y', twice (mul y z))

(* Add by first expressing both affine numerators over the same denominator. *)
let combine left u1 s1 u2 s2 z =
  let h = sub u2 u1 and r = sub s2 s1 in
  if Z.equal h Z.zero then (if Z.equal r Z.zero then double left else Infinity)
  else
    let hh = square h in
    let hhh = mul h hh and v = mul u1 hh in
    let x = sub (sub (square r) hhh) (twice v) in
    Jacobian (x, sub (mul r (sub v x)) (mul s1 hhh), mul h z)

let add_point a b = match a, b with
  | Infinity, p | p, Infinity -> p
  | Jacobian (x,y,z), Jacobian (xx,yy,zz) ->
      let z2 = square z and zz2 = square zz in
      combine a (mul x zz2) (mul y (mul zz zz2)) (mul xx z2) (mul yy (mul z z2)) (mul z zz)

let mixed a (x,y) = match a with
  | Infinity -> Jacobian (x,y,Z.one)
  | Jacobian (xx,yy,z) ->
      let z2 = square z in
      combine a xx yy (mul x z2) (mul y (mul z z2)) z

let encode = function
  | Infinity -> Z.shift_left (Z.of_int 3) 382
  | Jacobian (x,y,z) ->
      let zi = Z.invert z p in
      let scale = square zi in
      let x = mul x scale and y = mul y (mul zi scale) in
      let flags = if Z.gt y half then 5 else 4 in
      Z.logor x (Z.shift_left (Z.of_int flags) 381)

let commit coefficients =
  let n = Array.length coefficients in
  if n > Array.length points then fail "Too many DA coefficients";
  let width = if n < 32 then 3 else if n < 192 then 5 else if n < 640 then 7 else 9 in
  let buckets = Array.make (1 lsl width) Infinity in
  let bits = Array.fold_left (fun bits z -> max bits (Z.numbits z)) 0 coefficients in
  let acc = ref Infinity in
  for window = (bits + width - 1) / width - 1 downto 0 do
    for _ = 1 to width do acc := double !acc done;
    Array.fill buckets 0 (Array.length buckets) Infinity;
    Array.iteri (fun i v ->
        let digit = Z.to_int (Z.extract v (window * width) width) in
        if digit <> 0 then buckets.(digit) <- mixed buckets.(digit) (Lazy.force points.(i))) coefficients;
    let sum = ref Infinity in
    for digit = Array.length buckets - 1 downto 1 do
      sum := add_point !sum buckets.(digit);
      acc := add_point !acc !sum
    done
  done;
  let value = encode !acc in
  Felt.of_z (Z.extract value 0 192), Felt.of_z (Z.shift_right value 192)

let register reg =
  let open Hintrt in
  reg "GuessKzgCommitmentsAndStoreDaSegment" (fun c vm ->
      let data = get_ptr vm c "state_updates_start" and size = Felt.to_nat (get_felt vm c "da_size") in
      let blob = Z.to_int (const_z c "BLOB_LENGTH") in
      if blob <= 0 || blob > Array.length points then fail "Invalid KZG blob length";
      let count = (size + blob - 1) / blob in
      let commitments = Felt.reloc (Vm.add_temp_segment vm) 0 in
      let evals = Felt.reloc (Vm.add_temp_segment vm) 0 in
      set_val vm c "n_blobs" (Felt.small count);
      set_val vm c "kzg_commitments" commitments;
      set_val vm c "evals" evals;
      for i = 0 to count - 1 do
        let start = blob * i in
        let coefficients = Array.init (min blob (size-start)) (fun j -> z_at vm data (start+j)) in
        let low, high = commit coefficients in
        write_arg vm (Vm.reloc_add_felt commitments (Felt.small (2*i))) [low; high]
      done);
  reg "ComputeIdsLow" (fun c vm ->
      let d0 = get_member vm c "value" ["d0"] and d1 = get_member vm c "value" ["d1"] in
      let combined = Felt.add d0 (Felt.mul d1 (Felt.of_z (const_z c "BASE"))) in
      set_val vm c "low" (Felt.of_z (Z.extract (Felt.to_z combined) 0 128)));
  reg "WriteSplitResult" (fun c vm ->
      let value = get_z vm c "value" in
      write_arg vm (get_addr vm c "res")
        (Bls_field.split value))
