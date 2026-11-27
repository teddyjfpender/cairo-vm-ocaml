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
(** Steps that left the fast path ([--stats]). *)

val hint_steps : int ref
(** Executed pcs carrying hints ([--stats]). *)

external cpu_batch :
  int array -> int array -> Segment.seg array -> Builtin.flag array -> int array -> Segment.seg -> bytes -> int ->
  bool -> int array -> Felt.t array -> int = "cvm_cpu_batch_byte" "cvm_cpu_batch"
[@@noalloc]
(** Native kernel: run cached program-segment instructions until one needs
    the generic path; returns the number executed. *)

val run_fast : Vm.vm -> (Vm.vm -> unit) array array -> int -> unit
(** [run_fast vm hints end_seg] runs until pc = [end_seg:0], with the hints
    indexed by program-segment pc. Hints must not add relocation rules;
    use [run] otherwise. *)

val run : Vm.vm -> (Vm.vm -> unit) array array -> int -> unit
(** [run_fast], continuing in a rule-aware generic loop once a hint adds a
    relocation rule. *)
