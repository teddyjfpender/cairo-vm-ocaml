open Cairovm

let () =
  let vm = Vm.create ~trace:false and scopes = Hintrt.new_scopes () in
  let created = Dict.new_dict vm scopes None (Some Felt.zero) in
  let source = Dict.get_tracker scopes created in
  let key = Felt.small 71 and another = Felt.small 19 in
  Dict.dict_set source key Felt.one;
  let at_one = Dict.snapshot source in
  Dict.dict_set source key (Felt.small 2);
  let open_copy saved = Dict.get_tracker scopes (Dict.from_snapshot vm scopes saved) in
  let child = open_copy at_one and sibling = open_copy at_one in
  assert (Dict.dict_lookup child key = Felt.one);
  Dict.dict_set child key (Felt.small 3);
  Dict.dict_set child another (Felt.small 4);
  let grandchild = open_copy (Dict.snapshot child) in
  Dict.dict_set child another Felt.zero;
  assert (Dict.dict_lookup grandchild key = Felt.small 3);
  assert (Dict.dict_lookup grandchild another = Felt.small 4);
  assert (Dict.dict_lookup sibling key = Felt.one);
  assert (Dict.dict_lookup source key = Felt.small 2);
  assert (Dict.dict_lookup source another = Felt.zero);
  (match Dict.dict_lookup sibling another with exception Errors.Vm_error _ -> () | _ -> assert false);
  let external_inputs = Hintrt.Felt_tbl.create 1 in
  Hintrt.Felt_tbl.add external_inputs key Felt.one;
  let independent = Dict.get_tracker scopes (Dict.new_dict vm scopes (Some external_inputs) None) in
  Hintrt.Felt_tbl.replace external_inputs key Felt.zero;
  assert (Dict.dict_lookup independent key = Felt.one)
