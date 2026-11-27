(* Hint feeding the signature builtin (cairo-vm signature.rs). *)

open Errors
open Builtin
open Hintrt
module C = Hint_codes

let register reg =
  reg C.verify_ecdsa_signature (fun c vm ->
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
          Builtins_ext.add_signature (Felt.roff ptr) (r, s))
