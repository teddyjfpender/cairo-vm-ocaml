(** The hint table, built from every family module's [register]. *)

val compile : Program.t -> Hintrt.scopes -> Program.hint -> Vm.vm -> unit
(** The implementation of a hint, bound to its compiled context. Unknown
    codes compile to a hint that fails when executed. *)

val mem : string -> bool
(** Whether a hint code has a native implementation. *)
