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
  layout:string ->
  trace:bool ->
  secure:bool ->
  allow_missing_builtins:bool ->
  fill_holes:bool ->
  Pie_file.t ->
  result
(** Validate, load, execute and check. Fails with cairo-vm's messages. *)

val main_pc : Pie_file.t -> int
