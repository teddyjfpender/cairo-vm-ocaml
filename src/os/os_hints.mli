(** Initialize a runner with the sequencer stateless OS hint processor. *)
val initialize : ?layout_def:Layout.t -> ?record_trace:bool -> proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t

val configure_batch_gc : unit -> unit
(** Opt in to GC settings for a dedicated block runner process. Honors
    explicit OCaml runtime environment settings. *)

val run_output_file : path:string -> Runner.config -> Program.t -> string list
(** Run a fresh OS VM and return its formatted output words. An exclusive
    serial caller can reuse the program across blocks. Temporary field
    storage is released after each request. *)
