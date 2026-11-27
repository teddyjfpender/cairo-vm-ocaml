(** Runner mirroring cairo-vm v4.0.0's cairo_run: execution mode and
    canonical (Cairo 0) proof mode.

    Proof mode follows vm/src/vm/runners/cairo_runner.rs: every layout
    builtin gets a runner and a segment, the run starts at [__start__] with
    the stack [exec+2, 0, builtin bases...] and stops at [__end__] plus one
    step; [Finalize.end_run] pads the trace and finalizes the segments. *)

val layout_builtins : string -> Builtin.bkind list option
(** Builtins an execution-mode run may use in the named layout. *)

type config = {
  layout : string;
  trace : bool;
  secure_run : bool;
  allow_missing_builtins : bool;
  entrypoint : string;
}

(** Accessed-address bookkeeping for memory-hole counting, recovered from
    the trace (see [Resources]). *)
type accessed = {
  pending_temp : unit Hintrt.Felt_tbl.t;
  mutable bits : Bytes.t array;  (** per segment, one byte per offset *)
  mutable count : int array;  (** accessed cells per segment *)
  mutable cursor : int;  (** trace words processed *)
  mutable rc_lo : int;  (** instruction-offset bounds; [rc_lo > rc_hi] = none seen *)
  mutable rc_hi : int;
}

type t = {
  vm : Vm.vm;
  prog : Program.t;
  end_seg : int;  (** execution mode only *)
  hints : (Vm.vm -> unit) array array;
  prog_builtins : Builtin.bkind list;
  scopes : Hintrt.scopes;
  proof : bool;
  layout : Layout.t option;  (** proof mode only *)
  end_pc : int;  (** proof mode: offset of [__end__] in segment 0 *)
  initial_fp : int;
  mutable output_pages : (int * (int * int)) list;
  mutable output_attributes : (string * int list) list;
  mutable exec_public : int list;  (** reversed offsets of public execution memory *)
  mutable eff_sizes : int array option;  (** segment used sizes, fixed at end of run *)
  seg_sizes : (int, int) Hashtbl.t;  (** finalized segment sizes *)
  public_offsets : (int, (int * int) list) Hashtbl.t;  (** segment -> (offset, page) *)
  acc : accessed;
  mutable zero_seg : int;  (** mod builtins' zero segment, -1 if none *)
  mutable zero_size : int;
}

val entry_pc : config -> Program.t -> int
(** The pc of [config.entrypoint]. *)

val initialize :
  ?compile_hint:(Program.t -> Hintrt.scopes -> Program.hint -> Vm.vm -> unit) ->
  ?layout_def:Layout.t -> ?proof:bool -> config -> Program.t -> t
(** Validate the program's builtins against the layout, load the program and
    build the initial stack; [layout_def] overrides the proof-mode layout. *)

val run_for_steps : t -> int -> unit
(** Execute the given number of steps with hints. *)

val run_until_end : t -> unit
(** Execute to the end of the program (proof mode: one step past [__end__]). *)
