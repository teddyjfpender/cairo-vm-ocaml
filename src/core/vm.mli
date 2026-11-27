(** Machine state, write-once memory and Cairo value arithmetic.

    Semantics follow a formal executable model of starkware-libs/cairo-vm
    v4.0.0: operand addresses are computed from the original memory, missing
    op0/op1 are first deduced by the owning builtin, then by the Stone
    inverse rules; dst is deduced only from res (ASSERT_EQ) or fp (CALL).
    Deduced cells are written in op0, op1, dst order.

    Segment indices are non-negative for real segments and negative for
    temporary ones ([-1] is the first). *)

type vm = {
  mutable segs : Segment.seg array;
  mutable nsegs : int;
  mutable seg_flag : Builtin.flag array;
  mutable hi : int array;  (** used size: max written offset + 1 *)
  mutable seg_builtin : Builtin.builtin option array;
  mutable pc_seg : int;
  mutable pc : int;
  mutable ap : int;  (** offset in segment 1 *)
  mutable fp : int;
  mutable steps : int;
  mutable icache : int array;  (** decoded words of segment 0, 0 = not decoded *)
  trace_on : bool;
  mutable trace : Segment.seg;  (** packed entries or full pc, ap, fp triples *)
  mutable tlen : int;
  mutable builtins : Builtin.builtin list;
  mutable tsegs : Segment.seg array;  (** temporary segments *)
  mutable thi : int array;
  mutable ntsegs : int;
  mutable rules : (int * Felt.t) list;  (** temporary index -> destination *)
  mutable relocating : bool;
      (** a rule exists: reads translate temporary relocatables, so the
          interpreter leaves its fast path *)
  mutable had_temp : bool;
}

val create : trace:bool -> vm
(** An empty machine; [trace] preallocates the trace buffer. *)

val add_segment : vm -> int
(** Append a real segment and return its index. *)

val add_temp_segment : vm -> int
(** Append a temporary segment and return its (negative) index. *)

val seg_ok : vm -> int -> bool
(** Whether the index names an existing real segment. *)

val used_size : vm -> int -> int
(** Last assigned offset + 1 of a real segment. *)

(** {2 Memory} *)

val read : vm -> int -> int -> Felt.t
(** Unchecked read of a real segment (index and offset must be valid);
    [Felt.empty] past the capacity. *)

val temp_read : vm -> int -> int -> Felt.t
(** Read a temporary segment, failing on an unknown index. *)

val get : vm -> int -> int -> Felt.t
(** Checked read of any segment, applying the current relocation rules. *)

val write : vm -> int -> int -> Felt.t -> unit
(** Write-once store into a real segment, with builtin validation. *)

val write_checked : vm -> int -> int -> Felt.t -> unit
(** [write] for any segment, failing on an unknown index. *)

val grow_seg : vm -> int -> int -> unit
(** Grow a real segment's capacity to cover the offset. *)

val value_to_string : Felt.t -> string
(** Render a cell value for error messages. *)

(** {2 Temporary segments and relocation rules} *)

val add_relocation_rule : vm -> Felt.t -> Felt.t -> unit
(** cairo-vm Memory.add_relocation_rule (without extensive_hints). *)

val relocate_temp_value : vm -> Felt.t -> Felt.t
(** One application of the current rules to a value. *)

val relocate_temp_memory : vm -> unit
(** cairo-vm Memory.relocate_memory: rewrite temporary relocatables and move
    relocated temporary segments into real memory. *)

(** {2 Hooks installed by later modules} *)

val ecdsa_validate : (vm -> int -> int -> unit) ref
(** Signature builtin validation of a newly written cell. *)

val ext_step : (vm -> int -> unit) ref
(** Execute one decoded instruction carrying an opcode extension. *)

(** {2 Value arithmetic (MaybeRelocatable)} *)

val max_off : int
(** Largest relocatable offset. *)

val reloc_add_felt : Felt.t -> Felt.t -> Felt.t
(** Relocatable + felt; the result offset must stay in range. *)

val value_add : Felt.t -> Felt.t -> Felt.t
(** Sum of two felts or of a relocatable and a felt. *)

val value_mul : Felt.t -> Felt.t -> Felt.t
(** Field product; fails on relocatables. *)

val value_sub : Felt.t -> Felt.t -> Felt.t
(** Difference; two relocatables of one segment give a felt. *)
