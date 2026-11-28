(** Re-execution of a Cairo PIE (cairo-vm v4.0.0 cairo_run::cairo_run_pie,
    as driven by [cairo-vm-cli --run_from_cairo_pie]).

    The stripped program carries no hints: every value a hint produced in the
    original run is already in the PIE memory, which is loaded before the
    first step. The run is bounded by the PIE's [n_steps] (RunResources) and
    must reach the end pc. With [secure], the secure-runner checks run and
    the PIE the run would produce must match the input (metadata, memory,
    n_steps, builtin counters and every non-Pedersen additional data). *)

type result = {
  runner : Runner.t;
  output_pages : (int * (int * int)) list;  (** page id -> (start, size), from the PIE *)
  output_attributes : (string * int list) list;
  pedersen_extra : int list;  (** loaded Pedersen offsets (non-secure runs only) *)
}

val run :
  ?source:Pie_file.memory_source ->
  layout:string ->
  trace:bool ->
  secure:bool ->
  allow_missing_builtins:bool ->
  fill_holes:bool ->
  Pie_file.t ->
  result
(** Validate, load, execute and check. Fails with cairo-vm's messages. *)

val main_pc : Pie_file.t -> int

val write_output : ?compression_level:int -> secure:bool -> merge_extra_segments:bool -> result -> string -> unit
(** Serialize a completed replay, preserving builtin additional data. *)

val replay_file :
  ?layout:string -> ?trace:string -> ?memory:string -> ?output:string -> string -> unit
(** Securely re-execute a PIE and write the requested artifacts. Layout
    defaults to [all_cairo]. Calls must be serialized with all other VM runs
    in this process because the felt pool and builtin state are global. *)

val stripped_program : Pie_file.t -> Program.t

val load_subtask : ?source:Pie_file.memory_source -> Vm.vm -> Pie_file.t -> code:Felt.t -> stack:Felt.t -> ret_fp:Felt.t -> ret_pc:Felt.t -> unit
(** Load task memory using the simple bootloader's segment relocation map. *)

val output_data : Yojson.Safe.t -> (int * (int * int)) list * (string * int list) list
