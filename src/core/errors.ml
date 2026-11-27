exception Vm_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Vm_error s)) fmt
