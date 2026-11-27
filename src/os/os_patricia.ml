open Errors
open Hintrt
open Patricia_tree
module U = Yojson.Safe.Util
module C = Patricia_codes

let register ~block ~felt reg =
  let facts = Hashtbl.create 16 in
  let select c vm info initial final =
    let field key = felt (U.member key info) in
    if not (Felt.equal (field "tree_height") (Felt.of_z (const_z c "MERKLE_HEIGHT"))) then
      fail "Invalid commitment tree height";
    set_val vm c initial (field "previous_root");
    set_val vm c final (field "updated_root");
    Hashtbl.clear facts;
    U.to_assoc (U.member "commitment_facts" info) |> List.iter (fun (k, v) ->
        Hashtbl.replace facts (Felt.to_z (felt (`String k)))
          (preimage (List.map (fun x -> Felt.to_z (felt x)) (U.to_list v)))) in
  let roots name c vm = select c vm (U.member name (block ())) "initial_root" "final_root" in
  reg "ComputeCommitmentsOnFinalizedStateWithAliases" (fun _ _ -> ());
  reg "SetPreimageForClassCommitments" (roots "contract_class_commitment_info");
  reg "SetPreimageForStateCommitments" (roots "contract_state_commitment_info");
  reg "SetPreimageForCurrentCommitmentInfo" (fun c vm ->
      let address = get_felt vm c "contract_address" in
      let info = U.to_assoc (U.member "address_to_storage_commitment_info" (block ())) in
      match List.find_opt (fun (k, _) -> Felt.equal address (felt (`String k))) info with
      | Some (_, j) -> select c vm j "initial_contract_state_root" "final_contract_state_root"
      | None -> fail "Missing contract storage commitment");
  reg "ShouldUseReadOptimizedPatriciaUpdate" (fun c vm -> set_val vm c "should_use_read_optimized" Felt.one);
  let node c name = match var c.scopes name with
    | Patricia_node n -> n | _ -> fail "Missing Patricia tree node" in
  let map c = match var c.scopes "descent_map" with
    | Patricia_descents m -> m | _ -> fail "Missing Patricia descent map" in
  let enter_node c n =
    enter c.scopes ["node", Patricia_node n; "descent_map", Patricia_descents (map c)] in
  let children c = match node c "node" with
    | Branch (l,r) -> l,r | _ -> fail "Expected Patricia branch" in
  let bit vm c =
    match get_z vm c "bit" |> Z.to_int with 0 -> false | 1 -> true | _ -> fail "Invalid Patricia bit" in
  reg C.build (fun c vm ->
      let h = height (get_z vm c "height") and n = get_z vm c "n_updates" in
      let ptr = get_ptr vm c "update_ptr" in
      if not (Z.fits_int n) || Z.gt n (Z.of_int (Vm.max_off / 3)) then fail "Invalid Patricia update count";
      let tree = ref Empty in
      for i = 0 to Z.to_int n - 1 do
        let read j =
          let v = mem_at vm ptr (3*i+j) in
          if not (Felt.is_felt v) then fail "Expected integer in Patricia update";
          Felt.to_z v in
        let key = read 0 in
        ignore (read 2);
        if Z.numbits key > h then fail "Patricia update outside tree";
        tree := insert !tree h key
      done;
      let paths = descents facts h !tree (get_z vm c "prev_root") (get_z vm c "new_root") in
      set c.scopes "node" (Patricia_node !tree);
      set c.scopes "descent_map" (Patricia_descents paths));
  reg "descend = descent_map.get((ids.height, ids.path))\nmemory[ap] = 0 if descend is None else 1" (fun c vm ->
      match Hashtbl.find_opt (map c) (height (get_z vm c "height"), get_z vm c "path") with
      | None -> write_ap vm Felt.zero
      | Some (n, word) ->
          set c.scopes "descend_length" (Int (Z.of_int n)); set c.scopes "descend_word" (Int word);
          write_ap vm Felt.one);
  reg "ids.length, ids.word = descend" (fun c vm ->
      let fetch key = match var c.scopes key with Int z -> z | _ -> fail "Invalid Patricia descent" in
      set_int vm c "length" (fetch "descend_length"); set_int vm c "word" (fetch "descend_word"));
  reg C.descend (fun c vm ->
      let tree = ref (node c "node") and word = get_z vm c "word" in
      for i = height (get_z vm c "length") - 1 downto 0 do
        match !tree with Branch (l,r) -> tree := (if Z.testbit word i then r else l)
        | _ -> fail "Missing node on Patricia descent"
      done;
      enter_node c !tree);
  let decode c vm = let l,r = children c in write_ap vm (of_bool (l = Empty || r = Empty)) in
  List.iter (fun suffix -> reg ("from starkware.python.merkle_tree import decode_node\nleft_child, right_child, case = decode_node(node)\nmemory[ap] = " ^ suffix) decode)
    ["1 if case != 'both' else 0"; "int(case != 'both')"];
  let hashes c vm hash name = match lookup facts hash with
    | Binary (l,r) ->
        set_member vm c name ["x"] (Felt.of_z l); set_member vm c name ["y"] (Felt.of_z r)
    | _ -> fail "Expected binary Patricia preimage" in
  reg C.preimage_hashes (fun c vm -> hashes c vm (get_z vm c "node") "current_hash"; decode c vm);
  reg C.bottom (fun c vm -> hashes c vm (get_member_z vm c "edge" ["bottom"]) "hash_ptr");
  reg C.edge (fun c vm ->
      let hash = get_z vm c "node" in
      match lookup facts hash with
      | Edge {length;path;bottom} ->
          let n = Felt.small length in
          set_val vm c "edge" (gen_arg vm [n; Felt.of_z path; Felt.of_z bottom]);
          set_member vm c "hash_ptr" ["result"] (Felt.sub (Felt.of_z hash) n)
      | _ -> fail "Expected Patricia edge");
  reg "memory[ap] = 1 if ids.height == 0 or len(preimage[ids.node]) == 2 else 0" (fun c vm ->
      write_ap vm (of_bool (get_z vm c "height" = Z.zero ||
        match lookup facts (get_z vm c "node") with Binary _ -> true | _ -> false)));
  reg "ids.bit = (ids.edge.path >> ids.new_length) & 1" (fun c vm ->
      set_val vm c "bit" (of_bool (Z.testbit (get_member_z vm c "edge" ["path"]) (height (get_z vm c "new_length")))));
  reg "assert case == 'right'" (fun c _ -> if fst (children c) <> Empty then fail "Expected right Patricia branch");
  reg "memory[ap] = int(case != 'left')" (fun c vm -> write_ap vm (of_bool (snd (children c) <> Empty)));
  reg "memory[ap] = int(case == 'right') ^ ids.bit" (fun c vm ->
      write_ap vm (of_bool ((fst (children c) = Empty) <> bit vm c)));
  reg C.new_node (fun c vm ->
      let l,r = children c in
      set_val vm c "child_bit" (of_bool (r <> Empty));
      enter_node c (if r = Empty then l else r));
  reg C.next_zero (fun c vm -> let l,r = children c in enter_node c (if bit vm c then r else l));
  reg C.next_one (fun c vm -> let l,r = children c in enter_node c (if bit vm c then l else r));
  reg "vm_enter_scope(dict(node=left_child, **common_args))" (fun c _ -> enter_node c (fst (children c)));
  reg "vm_enter_scope(dict(node=right_child, **common_args))" (fun c _ -> enter_node c (snd (children c)));
  reg "vm_enter_scope(dict(node=node, **common_args))" (fun c _ -> enter_node c (node c "node"))
