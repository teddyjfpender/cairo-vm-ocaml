(** Segment and scope hints: segments.add, scopes, memcpy/memset loops,
    temporary arrays and segment relocation. *)

val register : Hintrt.registrar -> unit

val relocate : allow_felt:bool -> Hintrt.ctx -> Vm.vm -> unit
