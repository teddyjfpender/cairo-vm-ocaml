(** Cairo values as tagged immediates.

    A value is one OCaml int: 0 is an empty cell; tag 1 a small felt
    [(v lsl 2) lor 1] with |v| < 2^59; tag 2 a relocatable
    [(seg lsl 42) lor (off lsl 2) lor 2]; tag 3 a canonical big felt stored in
    the pool. [t] is private: values are built only through this module, so
    an offset or count can never be confused with a value. Raw C entry points
    below take untagged ints and are crossed explicitly with [(v :> int)]. *)

type t = private int

val unsafe_of_int : int -> t
(** Reinterpret a word read from memory or produced by the C kernel. *)

val empty : t

val p : Z.t
val half_p : Z.t
val small_bound : int
val off_bits : int
val off_mask : int
type pool = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
(** Big-felt storage: 32-byte slots of four little-endian u64 limbs. *)

external c_init : unit -> unit = "cvm_init"
external c_binop :
  pool ->
  (int [@untagged]) ->
  (int [@untagged]) ->
  (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_binop_byte" "cvm_binop" [@@noalloc]
external c_load_slot :
  pool -> (int [@untagged]) -> (int [@untagged]) -> unit
  = "cvm_load_slot_byte" "cvm_load_slot" [@@noalloc]
external c_code_of_slot :
  pool -> (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_code_of_slot_byte" "cvm_code_of_slot" [@@noalloc]
external c_big_eq :
  pool -> (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_big_eq_byte" "cvm_big_eq" [@@noalloc]
external c_bitwise :
  pool ->
  (int [@untagged]) ->
  (int [@untagged]) ->
  (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_bitwise_byte" "cvm_bitwise" [@@noalloc]
external c_cmp :
  pool -> (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_cmp_byte" "cvm_cmp" [@@noalloc]
external c_split_part :
  pool ->
  (int [@untagged]) ->
  (int [@untagged]) ->
  (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_split_part_byte" "cvm_split_part" [@@noalloc]
external c_bits : pool -> (int [@untagged]) -> (int [@untagged])
  = "cvm_bits_byte" "cvm_bits" [@@noalloc]
external c_pedersen :
  pool ->
  (int [@untagged]) ->
  (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_pedersen_byte" "cvm_pedersen" [@@noalloc]
external c_poseidon : pool -> (int [@untagged]) -> (int [@untagged]) -> unit
  = "cvm_poseidon_byte" "cvm_poseidon" [@@noalloc]
external c_keccak : pool -> (int [@untagged]) -> (int [@untagged]) -> unit
  = "cvm_keccak_byte" "cvm_keccak" [@@noalloc]
external c_ec_op :
  pool -> (int [@untagged]) -> (int [@untagged]) -> (int [@untagged])
  = "cvm_ec_op_byte" "cvm_ec_op" [@@noalloc]
external c_put_code :
  pool -> (int [@untagged]) -> bytes -> (int [@untagged]) -> unit
  = "cvm_put_code_byte" "cvm_put_code" [@@noalloc]
external keccak256_raw : bytes -> bytes -> unit = "cvm_keccak256"
external keccak_f_bytes : bytes -> unit = "cvm_keccak_f_bytes"
val scratch : int
val capacity : int
(** Slots in the pool's fixed reservation. *)

val pool : pool
(** Process-global and non-moving: a slot's address is stable for the run. *)

val pool_n : int ref
(** Next free slot. *)

val with_temporary_slots : (unit -> 'a) -> 'a
(** Exclusive serial execution. The callback must return or retain only
    results independent of the pool, and join readers before it returns.
    Both successful and failed runs release the slots allocated inside. *)

val intern : t -> t
(** A representative of a field value within the current allocation scope. *)

val reserve : int -> unit
(** [reserve k] raises [Out_of_memory] unless [k] slots are free. *)

val commit : t -> unit
val is_small : t -> bool
val both_small : t -> t -> bool
val is_big : t -> bool
val is_felt : t -> bool
val is_reloc : t -> bool
val small : int -> t
val small_val : t -> int
val reloc : int -> int -> t
val rseg : t -> int
val roff : t -> int
val zero : t
val one : t
val fits_small : int -> bool
val of_int : int -> t
val equal : t -> t -> bool
external c_big_hash : pool -> (int [@untagged]) -> (int [@untagged])
  = "cvm_big_hash_byte" "cvm_big_hash" [@@noalloc]
val mix : int -> int
(** Integer hash mix for immediate keys. *)

val hash : t -> int
val slow_binop : int -> t -> t -> t
val add : t -> t -> t
val sub : t -> t -> t
val mul_limit : int
val mul : t -> t -> t
val div : t -> t -> t option
val neg : t -> t
val split_at_limb : two_limbs:bool -> t -> t * t
val to_z : t -> Z.t
val of_hex_opt : string -> t option
(** Read one to 64 hexadecimal digits prefixed by 0x. Values must be below the field prime. *)

val of_z : Z.t -> t
val to_signed_z : t -> Z.t
val to_nat : t -> int
val compare : t -> t -> int
val bits : t -> int
val to_string : t -> string

(** {2 Hash and curve kernels} *)

val pedersen : t -> t -> t
val bitwise : int -> t -> t -> t
(** [bitwise op x y] with op 0 and, 1 xor, 2 or; [empty] when an input exceeds 2^251. *)

val poseidon : t array -> t array
(** Hades permutation of three felts. *)

val keccak : t array -> t array
(** Keccak-f1600 on eight 200-bit felts. *)

val ec_op : t array -> (t array, int) result
(** [p + m * q] for inputs [px; py; qx; qy; m]; [Error 1] on equal x
    coordinates, [Error 2] for a point off the curve, [Error 3] at infinity. *)
