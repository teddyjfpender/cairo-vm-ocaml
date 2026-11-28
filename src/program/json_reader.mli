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
  | Presence (* Validate the value, retaining only whether it is null. *)
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

val with_program_document :
  ?add_struct:((string, 'a) Hashtbl.t -> string -> int array -> int -> unit) ->
  ?word_offsets:int array option ref ->
  ?add_batch:((string, 'a) Hashtbl.t -> string -> int array -> int -> unit) ->
  ?reference_offsets:int array option ref ->
  add_identifier:((string, 'a) Hashtbl.t -> string -> Yojson.Safe.t -> unit) ->
  consume:((string, 'a) Hashtbl.t -> Yojson.Safe.t -> 'b) -> string -> 'b
(** Invoke the consumer once, after the complete document and debug metadata
    validate. The worker is joined on either a return value or an exception.
    Program.load_file can additionally consume canonical identifier and struct rows,
    bytecode word offsets and reference offsets. The ordinary projections handle other valid shapes;
    a speculative retry clears the previously collected offsets. *)

val with_program_slices :
  add_identifier:((string, 'a) Hashtbl.t -> string -> J.t -> unit) ->
  add_batch:((string, 'a) Hashtbl.t -> string -> int array -> int -> unit) ->
  add_struct:((string, 'a) Hashtbl.t -> string -> int array -> int -> unit) ->
  consume:(string -> int array option -> int array option -> (string, 'a) Hashtbl.t -> J.t -> 'b) ->
  bounds:int array -> fd:Unix.file_descr -> (unit -> string option) -> 'b option
(** Parse the root while native workers validate the removed debug value.
    [bounds] comes from [cvm_file_span] on this descriptor. Return [None] if
    a proposed endpoint, tile, compact root or descriptor stamp fails. *)
