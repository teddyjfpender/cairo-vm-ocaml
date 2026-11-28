(** CairoZero compiled-program JSON (cairo-compile output). *)

include module type of struct include Program_types end

exception Parse_error of string

val load_json : Yojson.Safe.t -> t
(** Read a compiled program.
    @raise Parse_error on a malformed or foreign field prime, or a malformed data word. *)

val load_file : string -> t
(** Read compiler JSON or native packed metadata. Raw compiler files require
    the six fields of the stock runner's program format. Recognized root
    fields occur once. The reader validates and discards [debug_info].
    @raise Yojson.Json_error on malformed JSON. *)

val pack : t -> string
(** Encode previously parsed compiler data for use by [load_file]. *)
