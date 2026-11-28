(** Reusable bytecode for independent runs of one compiled program. *)
type t
val prepare : Program.t -> t
(** Snapshot the program words and predecode ordinary Cairo instructions. *)

val load : t -> Program.t -> Vm.vm -> unit
(** Install into a freshly initialized plain program segment. *)
