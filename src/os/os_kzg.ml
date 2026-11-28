(* The sequencer commits to DA polynomial coefficients on BLS12-381 G1.
   Its public setup includes the monomial basis, so a multiscalar product
   gives the same commitment as evaluating the polynomial on the FFT domain
   and committing in the Lagrange basis. All inputs are public. *)
open Errors

let p = Z.of_string "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
module Curve = Weierstrass.Make (struct let prime = p let minus_three = false end)
open Curve
let half = Z.shift_right p 1
let setup_size = 4096

let points = lazy (Array.init setup_size (fun i -> lazy (
    let coordinate j = Z.of_bits (String.sub Kzg_setup.coordinates ((2*i+j)*48) 48) in
    coordinate 0, coordinate 1)))

let encode point = match affine point with
  | None -> Z.shift_left (Z.of_int 3) 382
  | Some (x,y) ->
      let flags = if Z.gt y half then 5 else 4 in
      Z.logor x (Z.shift_left (Z.of_int flags) 381)

let commit_reference coefficients =
  let n = Array.length coefficients in
  if n > setup_size then fail "Too many DA coefficients";
  let width = if n < 32 then 3 else if n < 192 then 5 else if n < 640 then 7 else 9 in
  let points = Lazy.force points in
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

let commit coefficients =
  let module Native = struct
    external msm : string -> bytes -> bytes -> unit = "cvm_bls_msm"
  end in
  let n = Array.length coefficients in
  if n > setup_size then fail "Too many DA coefficients";
  if Array.exists (fun z -> Z.sign z < 0 || Z.numbits z > 256) coefficients then
    commit_reference coefficients
  else begin
    let scalars = Bytes.make (32*n) '\000' in
    Array.iteri (fun i z ->
        let s = Z.to_bits z in Bytes.blit_string s 0 scalars (32*i) (String.length s)) coefficients;
    let bytes = Bytes.create 48 in
    Native.msm Kzg_setup.coordinates scalars bytes;
    let encoded = Z.of_bits (Bytes.unsafe_to_string bytes) in
    Felt.of_z (Z.extract encoded 0 192), Felt.of_z (Z.shift_right encoded 192)
  end

let register ?capture reg =
  let open Hintrt in
  reg "GuessKzgCommitmentsAndStoreDaSegment" (fun c vm ->
      let data = get_ptr vm c "state_updates_start" and size = Felt.to_nat (get_felt vm c "da_size") in
      Option.iter (fun save -> save vm data size) capture;
      let blob = Z.to_int (const_z c "BLOB_LENGTH") in
      if blob <= 0 || blob > setup_size then fail "Invalid KZG blob length";
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
