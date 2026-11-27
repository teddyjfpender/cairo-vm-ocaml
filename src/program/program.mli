(** CairoZero compiled-program JSON (cairo-compile output). *)

(** Reference expressions, as cairo-compile prints them. *)
type expr =
  | Reg_ap
  | Reg_fp
  | Int of Z.t
  | Deref of expr
  | Add of expr * expr
  | Sub of expr * expr
  | Mul of expr * expr
  | Neg of expr
  | Tuple of expr list
  | Cast of expr * string

type reference = {
  r_expr : expr;  (** the full value, e.g. [cast(fp + (-3), felt-pointer)]; [Int (-1)] if unparsable *)
  r_group : int;
  r_offset : int;
}

type hint = {
  code : string;
  scopes : string list;
  h_group : int;
  h_offset : int;
  ref_ids : (string * int) list;  (** full name -> reference index *)
}

type ident = {
  i_type : string;
  i_value : Z.t option;
  i_pc : int option;
  i_destination : string option;
  i_members : (string * int) list;  (** struct member offsets *)
  i_member_types : (string * string) list;
}

type t = {
  data : Z.t array;
  builtins : string list;
  main : int option;
  start : int option;
  end_ : int option;
  hints : (int * hint list) list;
  references : reference array;
  identifiers : (string, ident) Hashtbl.t;
}

exception Parse_error of string

val load_json : Yojson.Safe.t -> t
(** Read a compiled program. @raise Parse_error on a foreign field prime. *)

val load_file : string -> t
(** [load_json] of a file, skipping its [debug_info]. *)
