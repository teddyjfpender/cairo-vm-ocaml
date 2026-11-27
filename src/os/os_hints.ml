open Errors
open Hintrt
module U = Yojson.Safe.Util

let felt j =
  let z = Pie_file.z_of_json j in
  if Z.sign z < 0 || Z.geq z Felt.p then fail "OS input field element out of range";
  Felt.of_z z

let from_file ~accessed ~set_pages path =
  let hints = Yojson.Safe.from_file path in
  let input = U.member "os_input" hints and config = U.member "os_hints_config" hints in
  let blocks = U.to_list (U.member "os_block_inputs" input) in
  let classes = U.to_assoc (U.member "compiled_classes" input)
      |> List.map (fun (hash, cls) -> Z.of_string hash, cls)
      |> List.sort (fun (a, _) (b, _) -> Z.compare a b) in
  let deprecated = U.to_assoc (U.member "deprecated_compiled_classes" input) in
  let public_keys = match U.member "public_keys" config with
    | `Null -> [] | a -> List.map felt (U.to_list a) in
  let table = Hashtbl.create 32 in
  let reg code f = Hashtbl.add table code f in
  let compile = fun prog scopes (h : Program.hint) ->
    match Hashtbl.find_opt table h.code with
    | Some f -> f (make_ctx prog scopes h)
    | None -> Hints.compile prog scopes h in
  Legacy_class.register ~classes:deprecated ~felt ~compile reg;
  let segment vm = Felt.reloc (Vm.add_segment vm) 0 in
  let state_entries = ref None and class_entries = ref None in
  let pointer vm = function Some ptr -> ptr | None -> segment vm in
  let current = ref (-1) in
  let block () =
    match List.nth_opt blocks (max 0 !current) with
    | Some b when !current >= 0 -> b
    | _ -> fail "No current OS block" in
  let begin_block = Os_compression.register ~block ~felt
      ~state_initialized:(fun () -> Option.is_some !state_entries) reg in
  let calls = Os_calls.create () in
  Os_syscalls.register_deprecated calls ~felt reg;
  let begin_transactions = Os_transactions.register ~calls ~block ~felt reg in
  let structures = Felt_tbl.create (List.length classes) in
  Os_class_hash.register ~accessed ~structures reg;
  Os_da.register ~set_pages reg;
  Os_builtins.register reg;
  Os_state.register ~block ~felt reg;
  Os_patricia.register ~block ~felt reg;
  Os_block_hash.register ~block ~felt reg;
  reg "CheckIsDeprecated" (fun c vm ->
      let hash = get_member vm c "execution_context" ["class_hash"] in
      set_val vm c "is_deprecated" (of_bool (List.exists (fun (k,_) -> Felt.equal hash (felt (`String k))) deprecated)));
  reg "StarknetOsInput" (fun _ _ -> ());
  reg "memory[ap] = to_felt_or_relocatable(segments.add())" (fun _ vm -> write_ap vm (segment vm));
  reg "GetPublicKeys" (fun c vm ->
      set_val vm c "public_keys" (gen_arg vm public_keys);
      set_val vm c "n_public_keys" (Felt.small (List.length public_keys)));
  reg "GetBlocksNumber" (fun c vm -> set_val vm c "n_blocks" (Felt.small (List.length blocks)));
  reg "LoadClassesAndBuildBytecodeSegmentStructures" (fun c vm ->
      let facts = segment vm in
      set_val vm c "compiled_class_facts" facts;
      set_val vm c "n_compiled_class_facts" (Felt.small (List.length classes));
      List.iteri (fun i (hash, cls) ->
          let class_hash = Felt.of_z hash in
          let tree = Casm_class.load ~syscall:(Os_syscalls.run calls c) vm c ~felt ~class_hash
            ~fact:(Casm_class.at facts (2*i)) ~builtin_costs:(get_ptr vm c "builtin_costs") cls in
          Felt_tbl.replace structures class_hash tree) classes);
  reg "ChainIdAndFeeTokenAddress" (fun c vm ->
      let chain = U.member "chain_info" config in
      set_val vm c "chain_id" (felt (U.member "chain_id" chain));
      set_val vm c "fee_token_address" (felt (U.member "strk_fee_token_address" chain)));
  reg "SetStateUpdatePointersToNone" (fun _ _ -> state_entries := None; class_entries := None);
  reg "InitStateUpdatePointers" (fun _ vm ->
      state_entries := Some (segment vm); class_entries := Some (segment vm));
  reg "GuessStatePtr" (fun c vm -> set_val vm c "final_squashed_contract_state_changes_start" (pointer vm !state_entries));
  reg "GuessClassesPtr" (fun c vm -> set_val vm c "squashed_dict" (pointer vm !class_entries));
  reg "UpdateStatePtr" (fun c vm ->
      if Option.is_some !state_entries then state_entries := Some (get_ptr vm c "final_squashed_contract_state_changes_end"));
  reg "UpdateClassesPtr" (fun c vm ->
      if Option.is_some !class_entries then class_entries := Some (get_ptr vm c "squashed_dict_end"));
  reg "SegmentsAddTempInitialTxsRangeCheckPtr" (fun c vm ->
      set_val vm c "initial_txs_range_check_ptr" (Felt.reloc (Vm.add_temp_segment vm) 0));
  reg "LogRemainingBlocks" (fun c vm -> ignore (get_felt vm c "n_blocks"));
  reg "CreateBlockAdditionalHints" (fun _ _ -> incr current; begin_block (); begin_transactions ());
  reg "GetNClassHashesToMigrate" (fun c vm ->
      let hashes = U.to_list (U.member "class_hashes_to_migrate" (block ())) in
      set_val vm c "n_classes_to_migrate" (Felt.small (List.length hashes)));
  reg "WriteUseKzgDaAndFullOutputToMemory" (fun c vm ->
      let full = U.to_bool (U.member "full_output" config) in
      set_val vm c "use_kzg_da" (of_bool (U.to_bool (U.member "use_kzg_da" config) && not full));
      set_val vm c "full_output" (of_bool full));
  compile

let initialize ?layout_def ~proof ~path cfg prog =
  let runner = ref None in
  let accessed ptr length = Resources.range_accessed (Option.get !runner) ptr length in
  let set_pages pages attributes =
    let r = Option.get !runner in r.output_pages <- pages; r.output_attributes <- attributes in
  let compile_hint = from_file ~accessed ~set_pages path in
  let r = Runner.initialize ?layout_def ~compile_hint ~proof { cfg with Runner.trace = true } prog in
  runner := Some r;
  r
