(** The fast profile accepts compression levels 0 through 9. The two pinned
    profiles fix their encoding. A member emits the initialized prefix of each
    buffer and may reuse it after the sink returns. The production profile may
    replay the member emitter to fall back to the serial ZIP64 writer. *)
type profile = Fast | Rust_3_2 | Os_host_production

val write : ?profile:profile -> level:int -> string -> (string * ((bytes -> int -> unit) -> unit)) list -> unit
