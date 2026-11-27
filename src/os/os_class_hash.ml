open Errors
open Hintrt
open Casm_segments

(* Starknet's Blake2Felt252 packs the big-endian limbs of each field
   element as little-endian u32 words before applying BLAKE2s-256. *)
let blake fields =
  let state = ref (Blake2s.modified_iv ()) and block = Array.make 16 0 in
  let size = ref 0 and bytes = ref 0 in
  let compress final =
    bytes := !bytes + 4 * !size;
    state := Blake2s.compress !state block (!bytes land m32) (!bytes lsr 32) final 0 in
  let push word =
    if !size = 16 then begin compress 0; size := 0 end;
    block.(!size) <- word; incr size in
  List.iter (fun field ->
      let z = Felt.to_z field in
      let words = if Z.numbits z <= 63 then 2 else 8 in
      for i = words - 1 downto 0 do
        let word = Z.to_int (Z.extract z (32*i) 32) in
        push (if i = 7 then word lor (1 lsl 31) else word)
      done) fields;
  Array.fill block !size (16 - !size) 0;
  compress m32;
  Felt.of_z (Array.fold_right (fun word upper -> Z.(logor (shift_left upper 32) (of_int word))) !state Z.zero)

let register ~accessed ~structures reg =
  let current c = match var c.scopes "class_segment" with
    | Class_segment segment -> segment | _ -> fail "Missing class segment" in
  let enter_segment c n = enter c.scopes ["class_segment", Class_segment n] in
  let leaf n = match n.contents with Words _ -> true | Children _ -> false in
  reg "EnterScopeWithBytecodeSegmentStructure" (fun c vm ->
      let key = get_member vm c "compiled_class_fact" ["hash"] in
      match Felt_tbl.find_opt structures key with
      | Some n -> enter_segment c n | None -> fail "Missing segment structure for compiled class");
  reg "IsLeaf" (fun c vm -> set_val vm c "is_leaf" (of_bool (leaf (current c))));
  reg "AssignBytecodeSegments" (fun c _ ->
      match (current c).contents with
      | Children nodes -> set c.scopes "segments" (Class_segments nodes)
      | Words _ -> fail "Expected class segment with children");
  reg "AssertEndOfBytecodeSegments" (fun c _ ->
      match var c.scopes "segments" with Class_segments [] -> () | _ -> fail "Unconsumed class segments");
  reg "IterCurrentSegmentInfo" (fun c vm ->
      match var c.scopes "segments" with
      | Class_segments (node :: tail) ->
          set c.scopes "segments" (Class_segments tail);
          let ptr = get_ptr vm c "data_ptr" in
          let load = Felt.equal (get_felt vm c "full_contract") Felt.one || accessed ptr 1 in
          if not load && accessed ptr node.length then fail "Class segment accessed after unused start";
          set_val vm c "load_segment" (of_bool load);
          set_val vm c "is_leaf_and_loaded" (of_bool (load && leaf node));
          set_val vm c "segment_length" (Felt.small node.length);
          enter_segment c node
      | _ -> fail "Unexpected end of class segment iterator");
  reg "DeleteMemoryData" (fun c vm ->
      let ptr = get_ptr vm c "data_ptr" in
      let seg = Felt.rseg ptr and off = Felt.roff ptr in
      if accessed ptr 1 || not (Vm.seg_ok vm seg) || off >= Vm.used_size vm seg then
        fail "Cannot remove accessed or unallocated class word";
      Segment.sset vm.segs.(seg) off Felt.empty);
  reg "LoadClass" (fun c vm ->
      exit_scope c.scopes;
      if not (Felt.equal (get_felt vm c "hash") (get_member vm c "compiled_class_fact" ["hash"])) then
        fail "Inconsistent compiled class hash");
  reg "SetApToSegmentHashBlake" (fun c vm -> write_ap vm (hash blake (current c)));
  reg "SetApToSegmentHashPoseidon" (fun c vm -> write_ap vm (hash Os_block_hash.hash_many (current c)))
