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

type pool = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external c_init : unit -> unit = "cvm_init"
external pool_make : int -> pool = "cvm_pool_make"

external c_of_bits : pool -> string -> (int[@untagged]) -> (int[@untagged])
  = "cvm_of_bits_byte" "cvm_of_bits"
[@@noalloc]

external c_binop :
  pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  -> (int[@untagged]) = "cvm_binop_byte" "cvm_binop"
[@@noalloc]

external c_load_slot : pool -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_load_slot_byte" "cvm_load_slot"
[@@noalloc]

external c_code_of_slot : pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_code_of_slot_byte" "cvm_code_of_slot"
[@@noalloc]

external c_big_eq : pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_big_eq_byte" "cvm_big_eq"
[@@noalloc]

external c_bitwise :
  pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  -> (int[@untagged]) = "cvm_bitwise_byte" "cvm_bitwise"
[@@noalloc]

external c_cmp : pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_cmp_byte" "cvm_cmp"
[@@noalloc]

external c_split_part : pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  -> (int[@untagged]) -> (int[@untagged]) = "cvm_split_part_byte" "cvm_split_part"
[@@noalloc]

external c_bits : pool -> (int[@untagged]) -> (int[@untagged]) = "cvm_bits_byte" "cvm_bits"
[@@noalloc]

external c_pedersen :
  pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_pedersen_byte" "cvm_pedersen"
[@@noalloc]

external c_poseidon : pool -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_poseidon_byte" "cvm_poseidon"
[@@noalloc]

external c_keccak : pool -> (int[@untagged]) -> (int[@untagged]) -> unit
  = "cvm_keccak_byte" "cvm_keccak"
[@@noalloc]

external c_ec_op : pool -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_ec_op_byte" "cvm_ec_op"
[@@noalloc]

external c_put_code : pool -> (int[@untagged]) -> bytes -> (int[@untagged]) -> unit
  = "cvm_put_code_byte" "cvm_put_code"
[@@noalloc]

external keccak256_raw : bytes -> bytes -> unit = "cvm_keccak256"
external keccak_f_bytes : bytes -> unit = "cvm_keccak_f_bytes"

let () = c_init ()

(* ---- the big-felt pool ---- *)

let scratch = 64 (* slots 0..63 are scratch for multi-slot builtins *)
(* One fixed reservation of lazily committed pages: slots never move, so no
   growth copies, and running out fails explicitly. *)
let pool = pool_make (1 lsl 28)
let capacity = Bigarray.Array1.dim pool lsr 5 (* slots actually reserved *)
let pool_n = ref scratch

(* A standalone run returning only serialized results can reuse its slots.
   The caller owns the single VM thread and joins all artifact readers before
   leaving this scope. Values from surrounding live VMs lie below [first]. *)
(* Fail unless slots [pool_n .. pool_n + k) exist. *)
let[@inline] reserve k = if !pool_n + k > capacity then raise Out_of_memory

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

(* Field equality for felt codes; relocatables compare structurally. *)
let[@inline] equal a b =
  a = b || (a land 3 = 3 && b land 3 = 3 && c_big_eq pool a b = 1)

external c_big_hash : pool -> (int[@untagged]) -> (int[@untagged])
  = "cvm_big_hash_byte" "cvm_big_hash" [@@noalloc]

(* Small felts and relocatables are canonical immediates: an integer mix is a
   valid hash. Big felts hash their limbs. *)
let[@inline] mix x = let h = x * 0x9E3779B97F4A7C1 in h lxor (h lsr 29)
let hash v = if is_big v then c_big_hash pool v else mix v

module Keys = Hashtbl.Make (struct
  type t = int
  let equal = equal
  let hash = hash
end)

let interned = ref (Keys.create 64)

let intern v =
  if not (is_big v) then v else
    match Keys.find_opt !interned v with
    | Some existing -> existing
    | None -> Keys.add !interned v v; v

let with_temporary_slots f =
  let first = !pool_n and previous = !interned in
  interned := Keys.create 16;
  Fun.protect ~finally:(fun () -> interned := previous; pool_n := first) f


(* ---- field arithmetic on felt codes (caller guarantees felts) ---- *)

let[@inline never] slow_binop op a b =
  reserve 1;
  let c = c_binop pool op a b !pool_n in
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
    let c = c_binop pool 3 a b !pool_n in
    if c = 0 then None
    else begin
      commit c;
      Some c
    end
  end

let neg a = sub zero a

(* The only supported boundaries are one or two limbs. *)
let split_at_limb ~two_limbs c =
  if is_small c && small_val c >= 0 then c, zero
  else begin
    let use_two = Bool.to_int two_limbs in
    reserve 2;
    let part high =
      let result = c_split_part pool c use_two high !pool_n in
      commit result;
      result
    in
    let low = part 0 in
    low, part 1
  end

(* ---- conversion with Zarith ---- *)

let to_z c =
  if is_small c then begin
    let v = small_val c in
    if v >= 0 then Z.of_int v else Z.add p (Z.of_int v)
  end
  else begin
    let b = Bytes.create 32 in
    c_put_code pool c b 0;
    Z.of_bits (Bytes.unsafe_to_string b)
  end

external c_parse_hex : pool -> string -> (int[@untagged]) -> (int[@untagged])
  = "cvm_parse_hex_byte" "cvm_parse_hex" [@@noalloc]

let of_hex_opt s =
  reserve 1;
  let result = c_parse_hex pool s !pool_n in
  if result = 0 then None else begin commit result; Some result end

let of_z z =
  if Z.fits_int z && fits_small (Z.to_int z) then small (Z.to_int z)
  else begin
    let z = if Z.sign z >= 0 && Z.lt z p then z else Z.erem z p in
    reserve 1;
    let c = c_of_bits pool (Z.to_bits z) !pool_n in
    commit c;
    c
  end

(* Signed representative in (-p/2, p/2], as cairo-vm's signed_felt. *)
let of_int v =
  if fits_small v then small v else of_z (Z.of_int v)

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
  else c_cmp pool a b

let bits c = c_bits pool c

let to_string c = Z.to_string (to_z c)

type t = int
let[@inline] unsafe_of_int x = x
let empty = 0

(* ---- typed entry points to the C hash/EC kernels ----
   Inputs are loaded into reserved, uncommitted pool slots; outputs are
   canonicalized forward from the same base (the write cursor never overtakes
   an unread output), and only big results advance [pool_n]. *)

let pedersen a b =
  reserve 1;
  let r = c_pedersen pool a b !pool_n in
  commit r;
  r

(* op 0 and, 1 xor, 2 or; [empty] when an input exceeds 2^251 *)
let bitwise op x y =
  if both_small x y && x >= 0 && y >= 0 then
    match op with 0 -> x land y | 1 -> (x lxor y) lor 1 | _ -> x lor y
  else begin
    reserve 1;
    let r = c_bitwise pool op x y !pool_n in
    commit r;
    r
  end

let kernel (k : int -> int -> int) (inp : t array) n_out =
  let n_in = Array.length inp in
  reserve (n_in + n_out);
  let s = !pool_n in
  Array.iteri (fun i v -> c_load_slot pool v (s + i)) inp;
  let rc = k s (s + n_in) in
  if rc <> 0 then Error rc
  else
    Ok (Array.init n_out (fun i ->
        let r = c_code_of_slot pool (s + n_in + i) !pool_n in
        commit r;
        r))

let infallible = function Ok out -> out | Error _ -> assert false
let poseidon inp = infallible (kernel (fun i o -> c_poseidon pool i o; 0) inp 3)
let keccak inp = infallible (kernel (fun i o -> c_keccak pool i o; 0) inp 8)
let ec_op inp = kernel (fun i o -> c_ec_op pool i o) inp 2
