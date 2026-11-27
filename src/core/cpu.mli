(** The Cairo CPU: instruction fetch, the generic deduction step and the
    fast interpreter loop (with the native batch kernel). *)

val decode_at : Vm.vm -> int -> int -> int
(** Decode the instruction stored at [seg:off] (see {!Instruction}). *)

val record_trace : Vm.vm -> int -> int -> int -> int -> unit
(** [record_trace vm pc_seg pc ap fp] appends one trace entry: a packed word
    with low bit 1, or a relocatable pc code followed by ap and fp. The layout
    is shared with [cvm_write_trace]. *)

val step_instr : Vm.vm -> int -> unit
(** Execute one decoded Stone instruction with full deduction semantics. *)

val update : Vm.vm -> int -> int -> int -> int -> int -> int -> Felt.t -> Felt.t -> Felt.t -> int -> unit
(** [update vm d pc_seg pc ap fp size dst op1 res opcode] applies the
    register updates of instruction [d] and counts the step. *)

val step : Vm.vm -> unit
(** Execute the instruction at the current pc, without hints. *)

val hint_bit : int
(** Flag of a cached decoded word whose pc carries hints. *)

val generic_steps : int ref
(** Steps executed by the generic step rather than the native kernel ([--stats]). *)

val hint_steps : int ref
(** Executed pcs carrying hints ([--stats]). *)

external cpu_batch :
  int array -> int array -> Segment.seg array -> Builtin.flag array -> int array -> Segment.seg -> Felt.pool -> int ->
  bool -> Felt.t array -> int = "cvm_cpu_batch_byte" "cvm_cpu_batch"
[@@noalloc]
(** Native kernel: run up to 8,192 cached program-segment instructions
    (including a first instruction whose hints already ran) until one is
    uncached, flagged or needs the generic path; returns the number executed. *)

val run : ?stop:int * int -> ?steps:int -> Vm.vm -> (Vm.vm -> unit) array array -> unit
(** [run ~stop:(seg, pc) ~steps vm hints] runs, with the hints indexed by
    program-segment pc, until pc = [seg:pc] or after [steps] steps (by
    default neither). Once a hint adds a relocation rule, the remaining
    steps take the generic path. *)

val register_runtime_hints : Vm.vm -> segment:int -> pc:int -> (Vm.vm -> unit) array -> unit
(** Install the hint actions for a dynamically loaded instruction. *)
