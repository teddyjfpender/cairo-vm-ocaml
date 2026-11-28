(** Version 1 native witness transport. The payload is a bounded CBOR map. *)
val magic : string
val max_bytes : int
val decode : string -> Yojson.Safe.t
type input = Json of string | Binary of Yojson.Safe.t
val read_file : ?resident:bool -> string -> input
val write : out_channel -> Yojson.Safe.t -> unit
(** Encode a supplied in-memory witness tree directly as a frame, without
    rendering its values to JSON. *)
