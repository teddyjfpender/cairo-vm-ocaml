(** Cairo PIE output (cairo-vm v4.0.0 cairo_pie.rs and
    CairoRunner::get_cairo_pie). Members match cairo-vm's; ZIP compression is configurable. *)

val write :
  ?profile:Pie_zip.profile -> ?compression_level:int ->
  ?output_pages:(int * (int * int)) list ->
  ?output_attributes:(string * int list) list ->
  ?pedersen_extra:int list ->
  Runner.t -> main:int -> secure:bool -> merge_extra_segments:bool -> string -> unit
(** Write the PIE of an execution-mode run; [main] is the entrypoint pc. The
    compression level defaults to 0 (stored), with 1–9 selecting DEFLATE. Other
    optional arguments carry additional data loaded from an input PIE
    ([Pie_run]): output pages and attributes, and Pedersen offsets that
    count as verified. *)
