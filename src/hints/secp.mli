(** secp256k1 / secp256r1 / ed25519 hints and the num-bigint style number
    theory shared with the Uint384, Ec and Math hints. *)

val stark_p : Z.t
val secp_p : Z.t
val secp_n : Z.t
val secp_p_v2 : Z.t
(** 2^255 - 19 *)

val r1_p : Z.t
val r1_b : Z.t

val nonzero : Z.t -> unit
(** Fails with cairo-vm's division-by-zero error on zero. *)

val mod_floor : Z.t -> Z.t -> Z.t
val div_mod_floor : Z.t -> Z.t -> Z.t * Z.t

val div_mod : Z.t -> Z.t -> Z.t -> Z.t
(** [div_mod n m p]: n / m modulo p; fails when m is not invertible. *)

val mul_inv : Z.t -> Z.t -> Z.t
val is_quad_residue : Z.t -> Z.t -> bool
val sqrt_prime_power : Z.t -> Z.t -> Z.t option

val felt_max_halved : Z.t
(** (P - 1) / 2 for the Stark prime. *)

val felt_sqrt : Z.t -> Z.t option
(** Felt252::sqrt: the smaller root, or [None] for a non-residue. *)

val pack86_l : Felt.t array -> int -> Z.t
(** BigInt3::pack86 of three signed limbs from an offset. *)

val register : Hintrt.registrar -> unit

val register_cairo0 : Hintrt.registrar -> unit
(** cairo-vm's `cairo-0-secp-hints` feature set. *)
