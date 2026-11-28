(** Versioned execution metadata for a parsed Cairo compiler program. *)
val magic : string
exception Invalid of string
val encode : Program_types.t -> string
val decode : string -> Program_types.t
