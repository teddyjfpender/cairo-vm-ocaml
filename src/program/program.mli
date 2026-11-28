(** CairoZero compiled-program JSON (cairo-compile output). *)

include module type of struct include Program_types end

exception Parse_error of string

val load_json : Yojson.Safe.t -> t
(** Read a compiled program.
    @raise Parse_error on a malformed or foreign field prime, or a malformed data word. *)

val load_file : string -> t
(** Read compiler JSON or native packed metadata. The JSON reader validates
    the top-level [debug_info] and discards it.
    @raise Yojson.Json_error on malformed JSON. *)

val pack : t -> string
(** Encode previously parsed compiler data for use by [load_file]. *)
