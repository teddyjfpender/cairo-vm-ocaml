open Errors
open Hintrt
open Casm_segments

(* Starknet's Blake2Felt252 packs the big-endian limbs of each field
   element as little-endian u32 words before applying BLAKE2s-256. *)
external blake_fields : Felt.pool -> Felt.t array -> int -> int -> bytes -> unit
  = "cvm_blake_fields" [@@noalloc]

let blake_slice data start length =
  if start < 0 || length < 0 || start > Array.length data - length then fail "Invalid class hash slice";
  let bytes = Bytes.create 32 in
  blake_fields Felt.pool data start length bytes;
  Felt.of_z (Z.of_bits (Bytes.unsafe_to_string bytes))

let blake fields =
  let data = Array.of_list fields in
  blake_slice data 0 (Array.length data)

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
  reg "SetApToSegmentHashBlake" (fun c vm -> write_ap vm (hash ~leaf:blake_slice blake (current c)));
  reg "SetApToSegmentHashPoseidon" (fun c vm -> write_ap vm (hash ~leaf:(fun data start n -> Os_block_hash.hash_many (Array.sub data start n |> Array.to_list)) Os_block_hash.hash_many (current c)))
