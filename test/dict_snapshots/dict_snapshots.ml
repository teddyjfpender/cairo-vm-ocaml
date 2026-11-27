open Cairovm

let () =
  let vm = Vm.create ~trace:false and scopes = Hintrt.new_scopes () in
  let created = Hints.new_dict vm scopes None (Some Felt.zero) in
  let source = Hints.get_tracker scopes created in
  let key = Felt.small 71 and another = Felt.small 19 in
  Hints.dict_set source key Felt.one;
  let at_one = Hints.snapshot source in
  Hints.dict_set source key (Felt.small 2);
  let open_copy saved = Hints.get_tracker scopes (Hints.from_snapshot vm scopes saved) in
  let child = open_copy at_one and sibling = open_copy at_one in
  assert (Hints.dict_lookup child key = Felt.one);
  Hints.dict_set child key (Felt.small 3);
  Hints.dict_set child another (Felt.small 4);
  let grandchild = open_copy (Hints.snapshot child) in
  Hints.dict_set child another Felt.zero;
  assert (Hints.dict_lookup grandchild key = Felt.small 3);
  assert (Hints.dict_lookup grandchild another = Felt.small 4);
  assert (Hints.dict_lookup sibling key = Felt.one);
  assert (Hints.dict_lookup source key = Felt.small 2);
  assert (Hints.dict_lookup source another = Felt.zero);
  (match Hints.dict_lookup sibling another with exception Vm.Vm_error _ -> () | _ -> assert false);
  let external_inputs = Hashtbl.create 1 in
  Hashtbl.add external_inputs key Felt.one;
  let independent = Hints.get_tracker scopes (Hints.new_dict vm scopes (Some external_inputs) None) in
  Hashtbl.replace external_inputs key Felt.zero;
  assert (Hints.dict_lookup independent key = Felt.one)
