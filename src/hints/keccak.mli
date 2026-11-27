(** Keccak hints, with incremental sponge checkpoints for unsafe_keccak. *)

type keccak_cursors
(** A few retained sponge states for prefixes of one VM's memory. *)

val keccak_cursors : unit -> keccak_cursors
val keccak256 : Bytes.t -> Bytes.t

val keccak_input : Vm.vm -> Felt.t -> first:int -> int -> check_width:bool -> Bytes.t
(** [keccak_input vm data ~first length ~check_width]: [length] big-endian
    bytes from 16-byte words starting at word [first]. *)

val finalize_keccak : keccak_cursors -> Vm.vm -> Felt.t -> int -> Bytes.t
(** Keccak-256 of [n] full 16-byte words (unsafe_keccak_finalize). *)

val hash_byte_prefix : keccak_cursors -> Vm.vm -> Felt.t -> int -> Bytes.t
(** Keccak-256 of [length] bytes with checked word widths (unsafe_keccak). *)

val register : Hintrt.registrar -> unit
