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
  n_selected_builtins = n_selected_builtins - 1|} (fun c vm ->
      let count = cell c.scopes "n_selected_builtins" in
      match !count with
      | Value n ->
          let chosen = not (Felt.equal n Felt.zero) &&
            Felt.equal (mem_at vm (get_ptr vm c "selected_encodings") 0) (mem_at vm (get_ptr vm c "all_encodings") 0) in
          if chosen then count := Value (Felt.sub n Felt.one);
          set_val vm c "select_builtin" (of_bool chosen)
      | _ -> fail "Missing selected builtin count")
