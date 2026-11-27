(** The single error channel of the VM: every rejected input or invariant
    violation raises [Vm_error] with a cairo-vm compatible message. *)

exception Vm_error of string

val fail : ('a, unit, string, 'b) format4 -> 'a
(** [fail fmt ...] raises [Vm_error] with the formatted message. *)
