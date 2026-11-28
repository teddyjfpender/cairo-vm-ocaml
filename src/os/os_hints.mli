(** Initialize a runner with the sequencer stateless OS hint processor. *)
val initialize : ?virtual_os:bool -> ?image:Program_image.t -> ?layout_def:Layout.t -> ?record_trace:bool -> proof:bool -> path:string -> Runner.config -> Program.t -> Runner.t

val initialize_files : ?virtual_os:bool -> ?layout_def:Layout.t -> ?record_trace:bool -> proof:bool -> path:string -> Runner.config -> string -> Runner.t
(** Read the program and OS witness on separate domains, then initialize the VM. *)

val configure_batch_gc : unit -> unit
(** Opt in to GC settings for a dedicated block runner process. Honors
    explicit OCaml runtime environment settings. *)

val run_output_file : ?virtual_os:bool -> ?image:Program_image.t -> path:string -> Runner.config -> Program.t -> string list
(** Run a fresh OS VM and return its formatted output words. An exclusive
    serial caller can reuse the program across blocks. Temporary field
    storage is released after each request. *)

val felt : Yojson.Safe.t -> Felt.t
(** Decode a canonical field element from the sequencer's JSON. *)

val run_output_to_channel : ?virtual_os:bool -> ?image:Program_image.t -> path:string -> Runner.config -> Program.t -> out_channel -> unit
(** Execute the same fresh VM and stream its formatted output directly to a channel. *)
