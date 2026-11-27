(** Native CairoZero execution. The CLI's optional Rust delegation is separate.
    Run one VM at a time per process: the felt pool is process-global. *)

type config = Runner.config
type result = Runner.t

val default_config : config
val run : ?config:config -> ?fill_holes:bool -> Program.t -> result
val run_file : ?config:config -> ?fill_holes:bool -> string -> result
(** Return only after execution and the configured end-of-run checks succeed.
    Use [Runner.iter_output_lines], [Runner.write_memory] and, when
    [config.trace] is true, [Runner.write_trace] to consume the result. *)
