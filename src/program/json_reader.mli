(** Validate JSON and materialize the fields requested by the VM. *)
module J = Yojson.Safe
module U = Yojson.Safe.Util

val space : int64
val json_error : ('a, unit, string, 'b) format4 -> 'a
val string_end : string -> int -> int
val skip_value : string -> int -> int

type cache
val create_cache : unit -> cache
(** Bounded storage for immutable JSON objects. Use one cache per domain. *)

type projection =
  | Json
  | Program
  | Debug_info
  | Fields of (string * projection) list
  | Only of (string * projection) list
  | Values of projection
  | Elements of projection
  | Cached of cache (** Reuse a previously parsed object on exact source-byte equality. *)
  | Encoded
  | Offset

val identifier : projection
val tracking : projection
val reference_manager : projection
val hint_table : projection
val project_key : string -> int ref -> (string * projection) list -> (string * projection) list
val validate_schema : string -> int ref -> Program_metadata.schema -> Program_metadata.schema -> bool
val parse : ?identifiers:(string -> J.t -> unit) -> projection:projection -> start:int -> whole:bool -> string -> J.t

val from_string :
  ?identifiers:(string -> Yojson.Safe.t -> unit) -> ?projection:projection -> string -> Yojson.Safe.t
val from_file :
  ?identifiers:(string -> Yojson.Safe.t -> unit) -> ?projection:projection -> string -> Yojson.Safe.t
val from_offset : ?projection:projection -> string -> int -> Yojson.Safe.t

val program_document :
  add_identifier:((string, 'a) Hashtbl.t -> string -> Yojson.Safe.t -> unit) ->
  string -> (string, 'a) Hashtbl.t * Yojson.Safe.t
(** Read the complete compiler document and its identifiers. Large indented
    debug maps may be validated concurrently with independent program fields. *)
