(** End of run: return values, segment finalization and the secure-run
    checks (cairo-vm end_run / read_return_values / verify_secure_runner). *)

val end_run : ?fill_holes:bool -> Runner.t -> secure:bool -> allow_missing:bool -> unit
(** Relocate temporary memory, verify auto-deductions, read the builtin stop
    pointers and, with [secure], verify the run. Proof mode first pads the
    trace to a power of two until every layout resource check (builtin
    cells, range-check, memory and diluted units) passes, then fixes builtin
    segment sizes to their allocations and records the public memory.
    [allow_missing] accepts program builtins absent from the layout. *)
