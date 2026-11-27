(** Cairo PIE input (cairo-vm v4.0.0 CairoPie::read_zip_file): the zip
    container (stored or deflated members, zip64 extras) and the five members
    version.json, metadata.json, memory.bin, additional_data.json and
    execution_resources.json. Only what a re-execution needs is decoded; the
    memory stays in its serialized form (see [Pie_run]). *)

type seg_info = { index : int; size : int }

type t = {
  data : Z.t array;  (** stripped program bytecode *)
  builtins : string list;  (** program builtins, in program order *)
  main : int;
  program_segment : seg_info;
  execution_segment : seg_info;
  ret_fp_segment : seg_info;
  ret_pc_segment : seg_info;
  builtin_segments : (string * seg_info) list;
  extra_segments : seg_info list;
  memory : Bytes.t;  (** memory.bin: 40-byte cells, 8-byte address then 32-byte value *)
  n_steps : int;
  builtin_instance_counter : (string * int) list;  (** keys without the [_builtin] suffix *)
  additional : (string * Yojson.Safe.t) list;  (** additional_data.json, keys without the suffix *)
}

val cell_bytes : int
(** 40. *)

val n_cells : t -> int

type memory_source
val read_deferred : string -> t * memory_source
(** Open the archive and decode its metadata, leaving [memory] empty. *)
val iter_memory : memory_source -> (bytes -> unit) -> unit
(** Visit serialized cells in file order and check the member CRC. A chunk
    is valid only during its callback. *)

val read : string -> t
(** Read a PIE zip. Fails on a malformed archive, a missing member, a
    member whose CRC does not match, or an unknown builtin name. *)

val z_of_json : Yojson.Safe.t -> Z.t
(** A JSON integer of any size. *)

val int_of_json : Yojson.Safe.t -> int
(** A non-negative JSON integer that fits an OCaml int. *)
