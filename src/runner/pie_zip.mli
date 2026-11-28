(** Stream a ZIP32 archive. Each member calls its sink with the initialized
    prefix of a byte buffer, which it may reuse after the sink returns.
    Level 0 stores entries. Levels 1 through 9 use raw DEFLATE. *)
type profile = Fast | Stored_headers | Rust_3_2
(** [Stored_headers] writes the same stored bytes as [Fast] at level zero.
    It requires repeatable member producers, called twice to emit the final
    local header before the payload so a concurrent reader sees immutable bytes. *)

val write : ?profile:profile -> level:int -> string -> (string * ((bytes -> int -> unit) -> unit)) list -> unit
