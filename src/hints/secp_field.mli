(** Integers modulo the secp256k1/r1 and ed25519 hint primes, computed by the
    C kernel on 32-byte buffers instead of Zarith values. Results are the
    non-negative floor residues num-bigint's [mod_floor] gives. *)

type t
(** A value in [\[0, 2^256)]. *)

type modulus = private t

val modulus : Z.t -> modulus option
(** [Some] for p in (1, 2^256); other moduli stay on Zarith. *)

val of_z : Z.t -> t
(** Requires 0 <= z < 2^256. *)

val to_z : t -> Z.t
val add : modulus -> t -> t -> t
val sub : modulus -> t -> t -> t
val mul : modulus -> t -> t -> t

val div : modulus -> t -> t -> t option
(** [None] when the divisor is not invertible. *)

val pack : modulus -> Felt.t -> Felt.t -> Felt.t -> t
(** BigInt3 [d0 + d1 2^86 + d2 2^172] of signed felt limbs, reduced. *)

val exact_quotient : modulus -> Felt.t -> Felt.t -> Felt.t -> Felt.t option
(** The packed value divided by the modulus when that division is exact and
    the quotient is a felt below p in magnitude. *)

val limb86 : t -> int -> Felt.t
(** 86-bit limb i (0, 1 or 2) of BigInt3 split. *)
