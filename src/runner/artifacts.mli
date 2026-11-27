(** Relocation and the run's outputs: binary trace/memory files and the
    output builtin's printed lines. *)

val check_no_temp_values : Vm.vm -> unit
(** Fail if real memory still holds a temporary relocatable. *)

val relocation_table : Runner.t -> int array
(** Relocated base address of every segment (index [nsegs] is the end). *)

external c_write_trace : string -> Segment.seg -> int -> int array -> unit = "cvm_write_trace"
(** [c_write_trace path trace tlen table] writes the relocated binary trace. *)

val write_trace : Runner.t -> string -> unit
(** Write the relocated binary trace file. *)

val write_memory : Runner.t -> string -> unit
(** Write the relocated binary memory file. *)

val trace_bounds : Runner.t -> ((int * int * int * int) * (int * int * int * int)) option
(** First and last trace entries as [(pc_seg, pc, ap, fp)]. *)

val iter_output_lines : Runner.t -> (string -> unit) -> unit
(** Pass each output builtin cell, rendered as cairo-vm prints it. *)

val output_lines : Runner.t -> string list
(** The output builtin's cells, rendered as cairo-vm prints them. *)

val pedersen_verified : secure:bool -> Runner.t -> Builtin.builtin -> int list
(** Output offsets cairo-vm's pedersen runner records as verified. *)
