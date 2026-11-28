val initialize : ?image:Program_image.t -> ?layout_def:Layout.t -> ?on_da:(Felt.t array -> unit) ->
  proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t
(** Run with the sequencer aggregator hint processor. Blob output is delivered
    to the caller's callback when supplied. *)
