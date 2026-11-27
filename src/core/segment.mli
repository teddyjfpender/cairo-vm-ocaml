(** Memory segments: zeroed word arrays outside the OCaml heap. Every cell
    is an immediate, so there is nothing for the GC to scan or barrier.
    Memory cells hold [Felt.t] values (0 = empty); the trace reuses the
    storage for packed register words. Indices are unchecked: callers bound
    them by [slen]. *)

type seg = private (int, Bigarray.int_elt, Bigarray.c_layout) Bigarray.Array1.t

external seg_make : int -> seg = "cvm_zalloc"
(** A zeroed segment of the given length. *)

val empty_seg : seg
(** The shared length-0 segment. *)

val slen : seg -> int
(** Capacity in words. *)

val sget : seg -> int -> Felt.t
(** Cell value; [Felt.empty] when unassigned. *)

val sset : seg -> int -> Felt.t -> unit
(** Store a value without write-once checks. *)

val raw_get : seg -> int -> int
(** Raw word, for trace storage. *)

val raw_set : seg -> int -> int -> unit
(** Store a raw word, for trace storage. *)

val seg_grow : seg -> int -> seg
(** A copy of the segment with the new (larger) capacity. *)

val snapshot : seg -> int -> seg
(** Copy the first [n] words into independent storage. *)
