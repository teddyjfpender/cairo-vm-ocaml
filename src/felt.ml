(* Value codes.  Every memory cell and every intermediate VM value is one
   immediate OCaml int:

     0                         empty / unassigned
     (v lsl 2) lor 1           small felt v with |v| < 2^59 (v mod p)
     (seg lsl 42) lor (off lsl 2) lor 2
                               relocatable; off < 2^40, seg signed
     (i lsl 2) lor 3           big felt, canonical limbs in pool slot i

   Big felts are canonical and never small-representable, hence two felt
   codes denote the same field element iff they are equal, or both are big
   with equal limbs.  This makes the common case (small values, pointers)
   allocation-free with no indirection. *)

let p = Z.of_string "3618502788666131213697322783095070105623107215331596699973092056135872020481"
let half_p = Z.shift_right p 1
let small_bound = 1 lsl 59
let off_bits = 40
let off_mask = (1 lsl off_bits) - 1

external c_init : unit -> unit = "cvm_init"

external c_binop :
  bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  -> (int[@untagged]) = "cvm_binop_byte" "cvm_binop"
[@@noalloc]

external c_load_slot : bytes -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_load_slot_byte" "cvm_load_slot"
[@@noalloc]

external c_code_of_slot : bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_code_of_slot_byte" "cvm_code_of_slot"
[@@noalloc]

external c_big_eq : bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_big_eq_byte" "cvm_big_eq"
[@@noalloc]

external c_bitwise :
  bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  -> (int[@untagged]) = "cvm_bitwise_byte" "cvm_bitwise"
[@@noalloc]

external c_cmp : bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_cmp_byte" "cvm_cmp"
[@@noalloc]

external c_bits : bytes -> (int[@untagged]) -> (int[@untagged]) = "cvm_bits_byte" "cvm_bits"
[@@noalloc]

external c_pedersen :
  bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_pedersen_byte" "cvm_pedersen"
[@@noalloc]

external c_poseidon : bytes -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_poseidon_byte" "cvm_poseidon"
[@@noalloc]

external c_keccak : bytes -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_keccak_byte" "cvm_keccak"
[@@noalloc]

external c_ec_op : bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_ec_op_byte" "cvm_ec_op"
[@@noalloc]

external c_put_code : bytes -> (int[@untagged]) -> bytes -> (int[@untagged]) -> unit
  = "cvm_put_code_byte" "cvm_put_code"
[@@noalloc]

external keccak256_raw : bytes -> bytes -> unit = "cvm_keccak256"
external keccak_f_bytes : bytes -> unit = "cvm_keccak_f_bytes"

let () = c_init ()

(* ---- the big-felt pool ---- *)

let scratch = 64 (* slots 0..63 are scratch for multi-slot builtins *)
let pool = ref (Bytes.make (32 * 4096) '\000')
let pool_n = ref scratch

let[@inline never] grow_pool () =
  let b = !pool in
  let nb = Bytes.make (2 * Bytes.length b) '\000' in
  Bytes.blit b 0 nb 0 (Bytes.length b);
  pool := nb

(* Make sure slots [pool_n .. pool_n + k) exist. *)
let[@inline] reserve k = if (!pool_n + k) * 32 > Bytes.length !pool then grow_pool ()

let[@inline] commit code = if code land 3 = 3 && code asr 2 = !pool_n then incr pool_n

(* ---- predicates and constructors ---- *)

let[@inline] is_small c = c land 3 = 1
let[@inline] both_small a b = a land 3 = 1 && b land 3 = 1
let[@inline] is_big c = c land 3 = 3
let[@inline] is_felt c = c land 1 = 1
let[@inline] is_reloc c = c land 3 = 2
let[@inline] small v = (v lsl 2) lor 1
let[@inline] small_val c = c asr 2
let[@inline] reloc seg off = (seg lsl 42) lor (off lsl 2) lor 2
let[@inline] rseg c = c asr 42
let[@inline] roff c = (c lsr 2) land off_mask
let zero = small 0
let one = small 1

let[@inline] fits_small v = v > - small_bound && v < small_bound

let of_int v =
  if fits_small v then small v
  else begin
    reserve 1;
    let c = c_binop !pool 0 (small (v asr 1)) (small (v - (v asr 1))) !pool_n in
    commit c;
    c
  end

(* Field equality for felt codes; relocatables compare structurally. *)
let[@inline] equal a b =
  a = b || (a land 3 = 3 && b land 3 = 3 && c_big_eq !pool a b = 1)

(* ---- field arithmetic on felt codes (caller guarantees felts) ---- *)

let[@inline never] slow_binop op a b =
  reserve 1;
  let c = c_binop !pool op a b !pool_n in
  commit c;
  c

let[@inline] add a b =
  if both_small a b then begin
    let s = (a asr 2) + (b asr 2) in
    if fits_small s then small s else slow_binop 0 a b
  end
  else slow_binop 0 a b

let[@inline] sub a b =
  if both_small a b then begin
    let s = (a asr 2) - (b asr 2) in
    if fits_small s then small s else slow_binop 1 a b
  end
  else slow_binop 1 a b

let mul_limit = 1 lsl 29

let[@inline] mul a b =
  if both_small a b then begin
    let x = a asr 2 and y = b asr 2 in
    if x > - mul_limit && x < mul_limit && y > - mul_limit && y < mul_limit then small (x * y)
    else slow_binop 2 a b
  end
  else slow_binop 2 a b

(* None when dividing by zero. *)
let div a b =
  if b = zero then None
  else if both_small a b && (a asr 2) mod (b asr 2) = 0 then Some (small ((a asr 2) / (b asr 2)))
  else begin
    reserve 1;
    let c = c_binop !pool 3 a b !pool_n in
    if c = 0 then None
    else begin
      commit c;
      Some c
    end
  end

let neg a = sub zero a

(* ---- conversion with Zarith ---- *)

let to_z c =
  if is_small c then begin
    let v = small_val c in
    if v >= 0 then Z.of_int v else Z.add p (Z.of_int v)
  end
  else Z.of_bits (Bytes.sub_string !pool ((c asr 2) * 32) 32)

let small_limit_z = Z.of_int small_bound
let negative_small_limit = Z.sub p small_limit_z

let of_z z =
  if Z.fits_int z && fits_small (Z.to_int z) then small (Z.to_int z)
  else begin
    let z = if Z.sign z >= 0 && Z.lt z p then z else Z.erem z p in
    if Z.lt z small_limit_z then small (Z.to_int z)
    else if Z.gt z negative_small_limit then small (- Z.to_int (Z.sub p z))
    else begin
      let bits = Z.to_bits z in
      let len = String.length bits in
      reserve 1;
      let off = !pool_n * 32 in
      Bytes.blit_string bits 0 !pool off len;
      (* A short magnitude may reuse a slot touched by a builtin. *)
      Bytes.fill !pool (off + len) (32 - len) '\000';
      let c = (!pool_n lsl 2) lor 3 in
      incr pool_n;
      c
    end
  end

(* Signed representative in (-p/2, p/2], as cairo-vm's signed_felt. *)
let to_signed_z c =
  let z = to_z c in
  if Z.gt z half_p then Z.sub z p else z

(* Canonical value as non-negative OCaml int if < 2^62, else -1. *)
let to_nat c =
  if is_small c then (let v = small_val c in if v >= 0 then v else -1)
  else begin
    let z = to_z c in
    if Z.lt z (Z.shift_left Z.one 62) then Z.to_int z else -1
  end

let compare a b =
  if is_small a && is_small b && a asr 2 >= 0 && b asr 2 >= 0 then Stdlib.compare a b
  else c_cmp !pool a b

let bits c = c_bits !pool c

let to_string c = Z.to_string (to_z c)
