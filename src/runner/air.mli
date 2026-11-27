(** AIR public and private inputs (cairo-vm v4.0.0 air_public_input.rs,
    air_private_input.rs), serialized like serde_json::to_string_pretty. *)

val write_public_input : Runner.t -> string -> unit
(** Write the AIR public input of a proof-mode run. *)

val write_private_input : Runner.t -> trace_path:string -> memory_path:string -> string -> unit
(** Write the AIR private input of a proof-mode run, referencing the given
    trace and memory files. *)
