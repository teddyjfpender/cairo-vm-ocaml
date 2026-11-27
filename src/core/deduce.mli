(** Builtin auto-deduction of output cells (cairo-vm deduce_memory_cell). *)

val cache_get : Builtin.builtin -> int -> Felt.t
(** A previously deduced output at the offset, or [Felt.empty]. *)

val deduce_builtin : Vm.vm -> Builtin.builtin -> int -> int -> Felt.t
(** [deduce_builtin vm b seg off] computes (and caches) the output cell
    [seg:off] of [b]; [Felt.empty] for an input cell or missing inputs. *)

val deduce_cell : Vm.vm -> int -> int -> Felt.t
(** Deduce a cell of any segment; [Felt.empty] unless a deducing builtin owns it. *)
