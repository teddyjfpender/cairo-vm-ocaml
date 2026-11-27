(** Cairo PIE output (cairo-vm v4.0.0 cairo_pie.rs and
    CairoRunner::get_cairo_pie). Members match cairo-vm's; entries are stored
    uncompressed, so the zip container bytes differ. *)

val write : Runner.t -> main:int -> secure:bool -> merge_extra_segments:bool -> string -> unit
(** Write the PIE of an execution-mode run; [main] is the entrypoint pc. *)
