(* Hints driving the signature and mod builtins (cairo-vm v4.0.0
   hint_processor/builtin_hint_processor/{signature,mod_circuit}.rs). *)

open Errors
open Builtin
open Vm
open Hintrt

module C = Hint_codes

let find_builtin vm kind = List.find_opt (fun b -> b.kind = kind) vm.builtins

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

let register () =
  Hints.reg C.verify_ecdsa_signature (fun c vm ->
      let r = get_z vm c "signature_r" in
      let s = get_z vm c "signature_s" in
      let ptr = get_ptr vm c "ecdsa_ptr" in
      match find_builtin vm Ecdsa with
      | None -> fail "Expected ecdsa builtin to be present"
      | Some b ->
          if Felt.rseg ptr <> b.base then
            fail "Signature hint must point to the signature builtin segment, not %d:%d" (Felt.rseg ptr) (Felt.roff ptr);
          if Felt.roff ptr mod 2 <> 0 then
            fail "Signature hint must point to the public key cell, not %d:%d" (Felt.rseg ptr) (Felt.roff ptr);
          Builtins_ext.add_signature (Felt.roff ptr) (r, s));
  Hints.reg C.run_p_circuit (run_p_mod_circuit 1);
  (* With the mod_builtin feature cairo-vm hardcodes the large batch size to 8. *)
  Hints.reg C.run_p_circuit_with_large_batch_size (run_p_mod_circuit 8)
