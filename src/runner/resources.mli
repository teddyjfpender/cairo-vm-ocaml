(** Memory-access accounting, auto-deduction verification and the proof-mode
    layout resource checks that drive trace padding (cairo-vm cairo_runner.rs). *)

val trace_entry : Segment.seg -> int -> int * int * int * int * int
(** [trace_entry trace i] is [(next, pc_seg, pc, ap, fp)] for the entry at
    word [i] (see [Cpu.record_trace]). *)

val verify_auto_deductions : ?fill_holes:bool -> Vm.vm -> unit
(** Check every deducible builtin output against its deduction; with
    [fill_holes], also write missing outputs up to a whole instance. *)

exception Insufficient of string
(** The layout lacks capacity at the current step count. *)

val the_layout : Runner.t -> Layout.t
(** The proof-mode layout; fails in execution mode. *)

val div_ceil : int -> int -> int
(** Ceiling division of non-negative ints. *)

val used_cells : Runner.t -> Builtin.builtin -> int
(** Used cells of a builtin segment, as fixed at end of run. *)

val used_instances : Runner.t -> Builtin.builtin -> int
(** Used instances of a builtin. *)

val used_and_allocated : Runner.t -> Builtin.builtin -> int * int
(** Used and allocated cells of a builtin.
    @raise Insufficient when the usage exceeds the allocation. *)

val perm_range_check_limits : Runner.t -> (int * int) option
(** Min and max 16-bit range-check value over instruction offsets and
    range-check builtins. *)

val segment_size : Runner.t -> int -> int
(** Finalized size of a segment, else its used size. *)

val memory_holes : Runner.t -> int
(** Unaccessed cells within non-builtin segments. *)

val check_used_cells : Runner.t -> unit
(** All layout resource checks. @raise Insufficient on a shortfall. *)

val run_until_next_power_of_2 : Runner.t -> unit
(** Step until the step count is a power of two. *)

val with_pedersen_verifier : ((Vm.vm -> unit) -> 'a) -> 'a
(** Scope a single VM's preverification jobs. Submit after loading each task.
    Only one snapshot is in flight. All workers join on success or failure. *)

val with_preverified_pedersen : Vm.vm -> (unit -> 'a) -> 'a
(** Verify preloaded Pedersen triples concurrently with execution. *)

val range_accessed : Runner.t -> Felt.t -> int -> bool
(** Was any cell in this range accessed by an executed instruction? Requires tracing. *)

val relocate_memory : Runner.t -> unit
(** Relocate temporary segments and transfer accesses from earlier trace scans. *)
