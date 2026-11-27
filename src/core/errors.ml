(* The single error channel of the VM: every rejected input or invariant
   violation raises [Vm_error] with a cairo-vm compatible message. *)

exception Vm_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Vm_error s)) fmt
