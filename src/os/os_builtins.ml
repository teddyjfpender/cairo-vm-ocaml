open Errors
open Hintrt

let register reg =
  reg {|array_ptr = ids.array_ptr
elm_size = ids.elm_size
assert isinstance(elm_size, int) and elm_size > 0, \
    f'Invalid value for elm_size. Got: {elm_size}.'

n_elms = ids.n_elms
assert isinstance(n_elms, int) and n_elms >= 0, \
    f'Invalid value for n_elms. Got: {n_elms}.'
if '__find_element_max_size' in globals():
    assert n_elms <= __find_element_max_size, \
        f'find_element() can only be used with n_elms<={__find_element_max_size}. ' \
        f'Got: n_elms={n_elms}.'

for i in range(n_elms):
    if memory[array_ptr + elm_size * i] >= ids.key:
        ids.index = i
        ids.exists = 1 if memory[array_ptr + elm_size * i] == ids.key else 0
        break
else:
    ids.index = n_elms
    ids.exists = 0|} (fun c vm ->
      let ptr = get_ptr vm c "array_ptr" and key = get_felt vm c "key" in
      let stride = Felt.to_nat (get_felt vm c "elm_size") and count = Felt.to_nat (get_felt vm c "n_elms") in
      if stride <= 0 || count < 0 || count > Vm.max_off / stride then fail "Invalid search dimensions";
      let rec search i = if i = count then i,false else
        let value = mem_at vm ptr (i*stride) in
        if not (Felt.is_felt value) then fail "Expected integer in sorted array";
        let cmp = Felt.compare value key in
        if cmp >= 0 then i,cmp=0 else search (i+1) in
      let i,exists = search 0 in
      set_val vm c "index" (Felt.small i); set_val vm c "exists" (of_bool exists));
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
      | _ -> fail "Missing selected builtin count");
  reg "UpdateBuiltinPtrs" (fun c vm ->
      let n name = Felt.to_nat (get_felt vm c name) in
      let all = read_range vm (get_member vm c "builtin_params" ["builtin_encodings"]) (n "n_builtins") in
      let subset = read_range vm (get_ptr vm c "selected_encodings") (n "n_selected_builtins") in
      let selected = get_ptr vm c "selected_ptrs" and original = get_ptr vm c "builtin_ptrs" in
      let index = ref 0 in
      let values = List.mapi (fun i key ->
          if List.exists (Felt.equal key) subset then begin
            let v = mem_at vm selected !index in incr index; v
          end else mem_at vm original i) all in
      set_val vm c "return_builtin_ptrs" (gen_arg vm values))
