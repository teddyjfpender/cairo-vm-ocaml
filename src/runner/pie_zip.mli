(** The fast profile accepts compression levels 0 through 9. The two pinned
    profiles fix their encoding. A member emits the initialized prefix of each
    buffer and may reuse it after the sink returns. The production profile may
    replay the member emitter to fall back to the serial ZIP64 writer. *)
type profile = Fast | Stored_headers | Rust_3_2 | Os_host_production
(** [Stored_headers] writes the same stored bytes as [Fast] at level zero.
    Its repeatable member producers are called twice so a concurrent reader
    sees the final local header before the payload. *)

val write : ?profile:profile -> level:int -> string -> (string * ((bytes -> int -> unit) -> unit)) list -> unit
