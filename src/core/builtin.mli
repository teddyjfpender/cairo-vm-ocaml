(** Builtin kinds, their memory cell layout and per-run builtin state. *)

type bkind =
  | Output
  | Pedersen
  | Range_check
  | Ecdsa
  | Bitwise
  | Ec_op
  | Keccak
  | Poseidon
  | Range_check96
  | Add_mod
  | Mul_mod

val bname : bkind -> string
(** cairo-vm's builtin name, without the [_builtin] suffix. *)

val all_builtins : bkind list
(** Every builtin in canonical program order. *)

val bkind_of_name : string -> bkind option
(** Parse a builtin name, with or without the [_builtin] suffix. *)

val cells_per_instance : bkind -> int
(** Memory cells of one builtin instance. *)

val n_input_cells : bkind -> int
(** Leading input cells of one instance; the rest are deduced outputs. *)

type builtin = {
  kind : bkind;
  base : int;  (** segment index *)
  mutable stop_ptr : int;  (** final offset read at end of run, -1 before *)
  mutable cache : Felt.t array;  (** deduced outputs by offset, [Felt.empty] = none *)
}

(** {2 Segment flags}
    A per-segment code read by write validation and by the native CPU
    kernel; private so only this module can produce one. *)

type flag = private int

val k_plain : flag
(** No validation and no deduction. *)

val k_rc : flag
(** 128-bit range check. *)

val k_rc96 : flag
(** 96-bit range check. *)

val k_ecdsa : flag
(** Signature validation on write. *)

val flag_of : bkind -> flag
(** The flag of a builtin's segment. *)

val is_deducing : flag -> bool
(** Whether the segment's output cells are deduced by its builtin. *)
