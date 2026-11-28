open Errors
open Hintrt

let register reg =
  reg "vm_enter_scope({'n_selected_builtins': ids.n_selected_builtins})" (fun c vm ->
      enter c.scopes ["n_selected_builtins", Value (get_felt vm c "n_selected_builtins")]);
  reg {|# A builtin should be selected iff its encoding appears in the selected encodings list
# and the list wasn't exhausted.
# Note that testing inclusion by a single comparison is possible since the lists are sorted.
ids.select_builtin = int(
  n_selected_builtins > 0 and memory[ids.selected_encodings] == memory[ids.all_encodings])
if ids.select_builtin:
  n_selected_builtins = n_selected_builtins - 1|} (fun c ->
      let uses_frame_cell name offset =
        let rec strip = function Program.Cast (e, _) -> strip e | e -> e in
        match Hashtbl.find_opt c.refs name with
        | None -> false
        | Some r ->
            match strip r.Program.r_expr with
            | Program.Deref e ->
                (match strip e with
                 | Program.Reg_fp -> offset = 0
                 | Program.Add (Program.Reg_fp, Program.Neg (Program.Int n)) ->
                     Z.equal n (Z.of_int (-offset))
                 | Program.Add (Program.Reg_fp, Program.Int n) -> Z.equal n (Z.of_int offset)
                 | _ -> false)
            | _ -> false in
      let run vm =
        let count = cell c.scopes "n_selected_builtins" in
        match !count with
        | Value n ->
            let chosen = not (Felt.equal n Felt.zero) &&
              Felt.equal (mem_at vm (get_ptr vm c "selected_encodings") 0) (mem_at vm (get_ptr vm c "all_encodings") 0) in
            let remaining = if chosen then Felt.sub n Felt.one else n in
            if chosen then count := Value remaining;
            set_val vm c "select_builtin" (of_bool chosen);
            remaining
        | _ -> fail "Missing selected builtin count" in
      if uses_frame_cell "all_encodings" (-7) && uses_frame_cell "selected_encodings" (-5) &&
         uses_frame_cell "select_builtin" 0 then
          let publish n = cell c.scopes "n_selected_builtins" := Value (Felt.small n) in
          let rec descriptor = {Vm.action; publish}
          and armed = Some descriptor
          and action vm =
            let remaining = run vm in
            if Felt.is_small remaining && Felt.small_val remaining >= 0 then begin
              vm.Vm.selection_remaining <- Felt.small_val remaining;
              vm.Vm.selection <- armed
            end in
          action
      else fun vm -> ignore (run vm))
