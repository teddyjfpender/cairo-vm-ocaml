(* Hints filling the add_mod / mul_mod builtins (cairo-vm mod_circuit.rs). *)

open Errors
open Builtin
open Hintrt
module C = Hint_codes

let usize_of vm c name =
  let n = Felt.to_nat (get_felt vm c name) in
  if n < 0 then fail "ids.%s does not fit in usize" name;
  n

let run_p_mod_circuit batch_size c vm =
  let ptr name = let p = get_ptr vm c name in (Felt.rseg p, Felt.roff p) in
  let add_ptr = ptr "add_mod_ptr" in
  let mul_ptr = ptr "mul_mod_ptr" in
  let add_n = usize_of vm c "add_mod_n" in
  let mul_n = usize_of vm c "mul_mod_n" in
  let fetch kind p n =
    match find_builtin vm kind with
    | None -> fail "Expected %s builtin to be present" (bname kind)
    | Some b ->
        if Builtins_ext.batch_size b <> batch_size then
          fail "Expected %s builtin batch size to be %d" (bname kind) batch_size;
        Some (p, b, n)
  in
  let add = fetch Add_mod add_ptr add_n in
  let mul = fetch Mul_mod mul_ptr mul_n in
  Builtins_ext.fill_memory vm add mul

let register reg =
  reg C.run_p_circuit (run_p_mod_circuit 1);
  (* With the mod_builtin feature cairo-vm hardcodes the large batch size to 8. *)
  reg C.run_p_circuit_with_large_batch_size (run_p_mod_circuit 8)
