(* Segment and scope hints: segments.add, vm_enter/exit_scope, memcpy and
   memset loops, temporary arrays and segment relocation (cairo-vm
   memcpy_hint_utils.rs, memset_utils.rs, segments.rs). *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

(* memcpy and memset loops: n -= 1; ids.<flag> = 1 if n > 0 else 0, on
   felts as in cairo-vm (felts are never negative). *)
let step_loop flag c vm =
  let n = cell c.scopes "n" in
  match !n with
  | Value v when Felt.is_felt v ->
      let v = Felt.sub v Felt.one in
      n := Value v;
      set_val vm c flag (of_bool (not (Felt.equal v Felt.zero)))
  | _ -> fail "Variable n is not an integer"

let register reg =
  (* memory[ap] = segments.add() *)
  reg C.add_segment (fun _ vm -> write_ap vm (Felt.reloc (add_segment vm) 0));
  reg C.vm_enter_scope (fun c _ -> enter c.scopes []);
  reg C.vm_exit_scope (fun c _ -> exit_scope c.scopes);
  reg C.memcpy_enter_scope (fun c vm -> enter c.scopes [ ("n", Value (get_felt vm c "len")) ]);
  reg C.memcpy_continue_copying (fun c vm -> step_loop "continue_copying" c vm);
  reg C.memset_enter_scope (fun c vm -> enter c.scopes [ ("n", Value (get_felt vm c "n")) ]);
  reg C.memset_continue_loop (fun c vm -> step_loop "continue_loop" c vm);
  reg C.temporary_array (fun c vm -> set_val vm c "temporary_array" (Felt.reloc (add_temp_segment vm) 0));
  reg C.relocate_segment (fun c vm ->
      let src = get_ptr vm c "src_ptr" in
      (* cairo-vm: inside segment_arena (`infos` in scope) dest_ptr is
         recomputed as infos[0].end + 1 *)
      let infos = try Some (get_ptr vm c "infos") with Vm_error _ -> None in
      let dst =
        match infos with
        | Some infos ->
            let e = mem_at vm infos 1 in
            if not (Felt.is_reloc e) then fail "Expected relocatable at infos + 1";
            value_add e Felt.one
        | None -> get_ptr vm c "dest_ptr"
      in
      add_relocation_rule vm src dst)
