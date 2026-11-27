open Errors
open Hintrt
module U = Yojson.Safe.Util

(* Large block witnesses create many short-lived transaction and call records.
   Dedicated runner processes can increase the nursery without changing the
   GC settings of applications embedding the VM. *)
let configure_batch_gc () =
  if Sys.getenv_opt "OCAMLRUNPARAM" = None && Sys.getenv_opt "CAMLRUNPARAM" = None then begin
    let gc = Gc.get () in
    Gc.set {gc with minor_heap_size = max gc.minor_heap_size (4 lsl 20);
                    space_overhead = max gc.space_overhead 250}
  end

let felt_slow j =
  let z = Pie_file.z_of_json j in
  if Z.sign z < 0 || Z.geq z Felt.p then fail "OS input field element out of range";
  Felt.of_z z

let felt = function
  | `Int i when i >= 0 -> Felt.of_int i
  | `String s as j -> (match Felt.of_hex_opt s with Some value -> value | None -> felt_slow j)
  | j -> felt_slow j

let from_file ~os_program ~watch ~accessed ~set_pages path =
  (* Keep each transaction and its witnesses as validated JSON until the OS
     selects them. Only the active transaction's object graph stays live. *)
  let open Json_reader in
  let block_fields = Fields ["transactions", Elements Encoded; "tx_execution_infos", Elements Encoded] in
  let projection = Fields ["os_input", Fields ["os_block_inputs", Elements block_fields]] in
  let hints = Json_reader.from_file ~projection path in
  let input = U.member "os_input" hints and config = U.member "os_hints_config" hints in
  let blocks = U.to_list (U.member "os_block_inputs" input) in
  let rng = lazy (
      let hashes = List.map (fun b -> felt (U.member "new_block_hash" b)) blocks in
      let salt = match U.member "rng_seed_salt" config with `Null -> Felt.zero | v -> felt v in
      Os_rng.create (Os_block_hash.hash_many (hashes @ [salt]))) in
  let classes = U.to_assoc (U.member "compiled_classes" input)
      |> List.map (fun (hash, cls) -> Z.of_string hash, cls)
      |> List.sort (fun (a, _) (b, _) -> Z.compare a b) in
  let deprecated = U.to_assoc (U.member "deprecated_compiled_classes" input) in
  let deprecated_hashes = Felt_tbl.create (List.length deprecated) in
  List.iter (fun (key, _) -> Felt_tbl.add deprecated_hashes (felt (`String key)) ()) deprecated;
  let public_keys = match U.member "public_keys" config with
    | `Null -> [] | a -> List.map felt (U.to_list a) in
  let table = Hashtbl.create 32 in
  let reg code f = Hashtbl.add table code f in
  let compile = fun prog scopes (h : Program.hint) ->
    match Hashtbl.find_opt table h.code with
    | Some f -> f (make_ctx prog scopes h)
    | None -> Hints.compile prog scopes h in
  reg Hint_codes.relocate_segment (Segments.relocate ~allow_felt:true);
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
  let calls = Os_calls.create () and secp = Os_secp.create () in
  Deprecated_syscalls.register ~os_program calls ~felt reg;
  let begin_transactions = Os_transactions.register ~calls ~block ~felt reg in
  let structures = Felt_tbl.create (List.length classes) in
  Os_class_hash.register ~accessed ~structures reg;
  Os_da.register ~set_pages reg;
  Os_sha.register reg;
  Os_secp.register reg;
  Secp.register_cairo0 reg;
  Os_kzg.register reg;
  Os_builtins.register reg;
  Os_state.register ~block ~felt reg;
  Os_patricia.register ~block ~felt reg;
  Os_block_hash.register ~block ~felt reg;
  reg "GenerateDummyOsOutputSegment" (fun c vm ->
      let base = segment vm in
      write_arg vm base [segment vm; Felt.zero; Felt.zero];
      set_val vm c "outputs" base);
  reg "CheckIsDeprecated" (fun c vm ->
      let hash = get_member vm c "execution_context" ["class_hash"] in
      set_val vm c "is_deprecated" (of_bool (Felt_tbl.mem deprecated_hashes hash)));
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
      let syscall = Os_syscalls.bind calls ~block ~secp c in
      List.iteri (fun i (hash, cls) ->
          let class_hash = Felt.of_z hash in
          let tree = Casm_class.load ~watch ~rng ~syscall vm c ~felt ~class_hash
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
  reg "CreateBlockAdditionalHints" (fun _ _ -> incr current; Os_secp.reset secp; begin_block (); begin_transactions ());
  reg "GetNClassHashesToMigrate" (fun c vm ->
      let hashes = U.to_list (U.member "class_hashes_to_migrate" (block ())) in
      set_val vm c "n_classes_to_migrate" (Felt.small (List.length hashes)));
  reg "WriteUseKzgDaAndFullOutputToMemory" (fun c vm ->
      let full = U.to_bool (U.member "full_output" config) in
      set_val vm c "use_kzg_da" (of_bool (U.to_bool (U.member "use_kzg_da" config) && not full));
      set_val vm c "full_output" (of_bool full));
  compile

let initialize ?layout_def ?(record_trace=true) ~proof ~path cfg prog =
  let runner = ref None in
  let watch = not (record_trace || cfg.Runner.trace || proof) in
  let accessed ptr length =
    let r = Option.get !runner in
    if watch then Vm.watched_range r.Runner.vm ptr length else Resources.range_accessed r ptr length in
  let set_pages pages attributes =
    let r = Option.get !runner in r.output_pages <- pages; r.output_attributes <- attributes in
  let compile_hint = from_file ~os_program:prog ~watch ~accessed ~set_pages path in
  let r = Runner.initialize ?layout_def ~compile_hint ~proof { cfg with Runner.trace = not watch } prog in
  runner := Some r;
  r

let run_output_file ~path cfg prog =
  Felt.with_temporary_slots (fun () ->
      let r = initialize ~proof:false ~record_trace:false ~path cfg prog in
      Runner.run_until_end r;
      Finalize.end_run r ~secure:cfg.Runner.secure_run ~allow_missing:cfg.allow_missing_builtins;
      Artifacts.output_lines r)
