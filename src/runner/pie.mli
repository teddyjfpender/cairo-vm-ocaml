(** Cairo PIE output (cairo-vm v4.0.0 cairo_pie.rs and
    CairoRunner::get_cairo_pie). Members match cairo-vm's; entries are stored
    uncompressed, so the zip container bytes differ. *)

val write :
  ?output_pages:(int * (int * int)) list ->
  ?output_attributes:(string * int list) list ->
  ?pedersen_extra:int list ->
  Runner.t -> main:int -> secure:bool -> merge_extra_segments:bool -> string -> unit
(** Write the PIE of an execution-mode run; [main] is the entrypoint pc. The
    optional arguments carry additional data loaded from an input PIE
    ([Pie_run]): output pages and attributes, and Pedersen offsets that
    count as verified. *)
