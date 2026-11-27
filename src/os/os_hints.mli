(** Initialize a runner with the sequencer stateless OS hint processor. *)
val initialize : ?layout_def:Layout.t -> ?record_trace:bool -> proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t

val configure_batch_gc : unit -> unit
(** Opt in to GC settings for a dedicated block runner process. Honors
    explicit OCaml runtime environment settings. *)
