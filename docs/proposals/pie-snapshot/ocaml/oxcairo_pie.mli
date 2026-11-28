(** Proposed public module. Synchronous calls share the process admission gate. *)
type profile = Vm_3_2_0
type layout = All_cairo | Small
type artifact = Trace | Memory | Pie
type limits = {
  max_input_bytes : int64;
  max_inflated_bytes : int64;
  max_steps : int64;
  max_segment_cells : int64;
  max_output_bytes : int64;
}
type options = {
  profile : profile;
  layout : layout;
  outputs : artifact list;
  limits : limits;
}
type code = Argument | Unsupported | Busy | Format | Execution | Mismatch
          | Limit | No_memory | Internal | Absent | Poisoned
type error = { code : code; message : string }
type snapshot
val default_options : options
val run : options -> zip:string -> (snapshot, error) result

(** Blobs own detached immutable storage. Keeping a blob keeps its data alive,
    including after its snapshot becomes unreachable. *)
type blob
val find : snapshot -> artifact -> blob option
val length : blob -> int
val blit : blob -> src_off:int -> bytes -> dst_off:int -> len:int -> unit
(** Invalid ranges raise Invalid_argument. No copying occurs until blit.
    Drop all references to release via GC. Rust/C have deterministic release. *)
