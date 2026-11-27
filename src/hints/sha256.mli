(** SHA-256 compression and the sha256 hints. *)

val iv : int array
(** The SHA-256 initial hash value (8 words). *)

val compress : int array -> int array -> int array
(** [compress state block]: the state after one 16-word block. *)

val digest : string -> string
(** The 32-byte SHA-256 digest of a message. *)

val register : Hintrt.registrar -> unit
