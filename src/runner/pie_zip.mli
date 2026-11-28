(** Stream a ZIP32 archive. Each member calls its sink with the initialized
    prefix of a byte buffer, which it may reuse after the sink returns.
    Level 0 stores entries. Levels 1 through 9 use raw DEFLATE. *)
val write : level:int -> string -> (string * ((bytes -> int -> unit) -> unit)) list -> unit
