(** Initialize a runner with the sequencer stateless OS hint processor. *)
val initialize : ?layout_def:Layout.t -> proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t
