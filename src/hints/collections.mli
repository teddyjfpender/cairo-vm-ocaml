(** Array search, set membership and usort hints. *)

type lower_cursor
module Set_words : Hashtbl.S with type key = Felt.t

type complete_rows

(** Per-hint index over one set range: the earliest row of each first word,
    and full rows once first words keep colliding. *)
type set_index = private {
  owner : Vm.vm;
  base : Felt.t;
  width : int;
  first : int Set_words.t;
  mutable composite : complete_rows option;
  mutable scanned : int; (** cell offset of the next unindexed row *)
}

val search_lower : lower_cursor option ref -> Vm.vm -> Felt.t -> int -> int -> Felt.t -> int
(** [search_lower cursor vm array width length key]: the first row whose
    first word is at least [key] (or a relocatable), else [length]. The cursor
    memoizes one array between calls. *)

val find_set_element : set_index option ref -> Vm.vm -> Felt.t -> int -> Felt.t array -> int
(** [find_set_element cache vm base total elm]: the row index of [elm] among
    the [total / Array.length elm] rows at [base], or -1. *)

val register : Hintrt.registrar -> unit
