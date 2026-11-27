(** Blake2s compression and the blake2s hints. *)

val compress : int array -> int array -> int -> int -> int -> int -> int array
(** [compress h msg t0 t1 f0 f1]: one Blake2s compression of the 8-word state
    [h] with the 16-word block [msg], counters [t0, t1] and finalization flags
    [f0, f1] (all 32-bit words). *)

val register : Hintrt.registrar -> unit

val modified_iv : unit -> int array
(** Fresh initial state for BLAKE2s-256 with an empty key. *)
