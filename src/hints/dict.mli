(** Dict manager, dict access and squash_dict hints. *)

open Hintrt

val get_tracker : scopes -> Felt.t -> dict_tracker
(** The tracker of the dict whose current pointer is the given one. *)

val dict_lookup : dict_tracker -> Felt.t -> Felt.t
(** The value of a canonical key, or the default. *)

val dict_set : dict_tracker -> Felt.t -> Felt.t -> unit
val dict_entries : dict_tracker -> (Felt.t * Felt.t) list

val snapshot : dict_tracker -> snapshot
(** Freeze the tracker's data; later writes go to its change map. *)

val new_dict : Vm.vm -> scopes -> Felt.t Felt_tbl.t option -> Felt.t option -> Felt.t
(** A new dict segment from optional initial contents and default value;
    returns its pointer. *)

val from_snapshot : Vm.vm -> scopes -> snapshot -> Felt.t
(** A new dict segment sharing a snapshot's contents. *)

val register : Hintrt.registrar -> unit
