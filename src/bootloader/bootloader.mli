(** Run the simple bootloader with Cairo 0 program and Cairo PIE tasks. *)
val initialize : ?layout_def:Layout.t -> proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t
