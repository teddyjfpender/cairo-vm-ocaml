(** Cairo layouts with the instance parameters proof mode needs, mirroring
    cairo-vm v4.0.0 vm/src/types/layout.rs and instance_definitions/*.rs. *)

val with_mod_builtin : bool
(** Whether layouts include the mod builtins (always in v4; v3.2.0 gated
    them behind a cargo feature off in the default CLI build). *)

type ratio = { num : int; den : int }
(** Steps per builtin instance as [num / den]; [num] = 0 is the dynamic
    layout's ratio 0. *)

type diluted = { units_per_step : int; fractional : bool; spacing : int; n_bits : int }
(** Diluted pool; [fractional] means [units_per_step] steps per unit. *)

type t = {
  name : string;
  cpu_component_step : int;
  rc_units : int;
  memory_units_per_step : int;
  public_memory_fraction : int;
  diluted : diluted option;
  builtins : (Builtin.bkind * ratio) list;  (** canonical order; Output has a dummy ratio *)
}

val of_name : string -> t option
(** A named static layout. *)

val dynamic_of_file : string -> t
(** The dynamic layout from a CairoLayoutParams JSON file. *)

val builtin_kinds : t -> Builtin.bkind list
(** The layout's builtins in canonical order. *)

val instances_per_component : Builtin.bkind -> int
(** Builtin instances per AIR component. *)

val n_parts : Builtin.bkind -> int
(** 16-bit range-check parts per cell of a range-check builtin, else 0. *)

val used_diluted_units : Builtin.bkind -> int -> int -> int
(** [used_diluted_units kind spacing n_bits]: diluted units per instance. *)
