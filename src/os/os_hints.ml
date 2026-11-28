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

let felt = Os_input.felt

type input = { document : Yojson.Safe.t; source : string; virtual_os : bool; prepared : Legacy_class.Prepared.t option }

let classes_cache = Domain.DLS.new_key Json_reader.create_cache

let read_input ?cache ?(prepare=false) ~virtual_os path =
  (* Keep each transaction and its witnesses as validated JSON until the OS
     selects them. Only the active transaction's object graph stays live. *)
  let open Json_reader in
  let info = if virtual_os then Os_calls.execution_projection else Offset in
  let block_fields = Fields ["transactions", Elements Offset; "tx_execution_infos", Elements info] in
  let fields = ["os_block_inputs", Elements block_fields] in
  let fields = match cache with
    | None -> fields
    | Some c -> ("compiled_classes", Values (Cached c)) :: ("deprecated_compiled_classes", Values (Cached c)) :: fields in
  let projection = Fields ["os_input", Fields fields] in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let hints = Json_reader.from_string ~projection source in
  if virtual_os then begin
    let blocks = U.to_list (U.member "os_block_inputs" (U.member "os_input" hints)) in
    List.iter (fun block ->
        List.iter Os_calls.validate_virtual_resources (U.to_list (U.member "tx_execution_infos" block))) blocks
  end;
  let prepared = if prepare then
      Legacy_class.Prepared.start (U.member "deprecated_compiled_classes" (U.member "os_input" hints))
    else None in
  {document=hints; source; virtual_os; prepared}

let register ?on_da ~os_program ~watch ~accessed ~set_pages {document=hints; source; virtual_os; prepared} =
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
  let reg, compile = Hints.extend () in
  reg Hint_codes.relocate_segment (Segments.relocate ~allow_felt:true);
  Legacy_class.register ?prepared ~classes:deprecated ~felt ~compile reg;
  let segment vm = Felt.reloc (Vm.add_segment vm) 0 in
  let state_entries = ref None and class_entries = ref None in
  let pointer vm = function Some ptr -> ptr | None -> segment vm in
  let remaining = ref blocks and current = ref None in
  let block () = match !current with Some b -> b | None -> fail "No current OS block" in
  let begin_block = Os_compression.register ~block ~felt
      ~state_initialized:(fun () -> Option.is_some !state_entries) reg in
  let calls = Os_calls.create () and secp = Os_secp.create () in
  Deprecated_syscalls.register ~os_program calls ~felt reg;
  let begin_transactions = Os_transactions.register ~os_program ~source ~virtual_os ~calls ~block ~felt reg in
  let structures = Felt_tbl.create (List.length classes) in
  Os_class_hash.register ~accessed ~structures reg;
  Os_da.register ~set_pages reg;
  Os_sha.register reg;
  Os_secp.register reg;
  Secp.register_cairo0 reg;
  let capture = Option.map (fun save vm base size ->
      save (Array.init size (mem_at vm base))) on_da in
  Os_kzg.register ?capture reg;
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
  reg "CreateBlockAdditionalHints" (fun _ _ ->
      current := Some (Os_calls.pop "block" remaining);
      Os_secp.reset secp; begin_block (); begin_transactions ());
  reg "GetNClassHashesToMigrate" (fun c vm ->
      let hashes = U.to_list (U.member "class_hashes_to_migrate" (block ())) in
      set_val vm c "n_classes_to_migrate" (Felt.small (List.length hashes)));
  reg "WriteUseKzgDaAndFullOutputToMemory" (fun c vm ->
      let full = U.to_bool (U.member "full_output" config) in
      set_val vm c "use_kzg_da" (of_bool (U.to_bool (U.member "use_kzg_da" config) && not full));
      set_val vm c "full_output" (of_bool full));
  compile

let initialize_input ?on_da ?image ?layout_def ?(record_trace=true) ~proof hints cfg prog =
  let runner = ref None in
  let trace = record_trace || cfg.Runner.trace || proof in
  (* Execution-mode class witnesses only query segment ranges registered while
     loading CASM. Track these directly even when the caller also wants a trace.
     Proof-mode resource accounting still consumes the complete trace. *)
  let watch = not proof in
  let accessed ptr length =
    let r = Option.get !runner in
    if watch then Vm.watched_range r.Runner.vm ptr length else Resources.range_accessed r ptr length in
  let set_pages pages attributes =
    let r = Option.get !runner in r.output_pages <- pages; r.output_attributes <- attributes in
  let compile_hint = register ?on_da ~os_program:prog ~watch ~accessed ~set_pages hints in
  let r = Runner.initialize ?image ?layout_def ~compile_hint ~proof { cfg with Runner.trace = trace } prog in
  runner := Some r;
  r

let initialize ?on_da ?(virtual_os=false) ?image ?layout_def ?record_trace ~proof ~path cfg prog =
  let cache = Option.map (fun _ -> Domain.DLS.get classes_cache) image in
  let hints = read_input ?cache ~virtual_os path in
  initialize_input ?on_da ?image ?layout_def ?record_trace ~proof hints cfg prog

let initialize_files ?on_da ?(virtual_os=false) ?layout_def ?record_trace ~proof ~path cfg program_path =
  (* Parsing only produces immutable program and witness data. VM setup and
     all accesses to its felt pool remain on the caller's domain. *)
  let worker =
    if Domain.recommended_domain_count () < 2 then None
    else
      (* New domains use the startup nursery size. Carry over the caller's
         witness allocation budget to avoid collecting its young objects while
         the program loader is still filling the large compiler document. *)
      let words = (Gc.get ()).minor_heap_size in
      try Some (Domain.spawn (fun () ->
          let gc = Gc.get () in
          if gc.minor_heap_size < words then Gc.set {gc with minor_heap_size = words};
          read_input ~prepare:true ~virtual_os path)) with Failure _ -> None in
  let program =
    match Program.load_file program_path with
    | p -> p
    | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Option.iter (fun d -> try
            let input = Domain.join d in
            Option.iter Legacy_class.Prepared.finish input.prepared
          with _ -> ()) worker;
        Printexc.raise_with_backtrace exn backtrace in
  let input = match worker with Some d -> Domain.join d | None -> read_input ~virtual_os path in
  (* Hashing may overlap runner setup. A caller can discard even a successfully
     initialized runner without leaving any speculative work in flight. *)
  Fun.protect (fun () -> initialize_input ?on_da ?layout_def ?record_trace ~proof input cfg program)
    ~finally:(fun () -> Option.iter Legacy_class.Prepared.finish input.prepared)

external batch_pedersen_cache : bool -> bool = "cvm_batch_pedersen_cache" [@@noalloc]

let with_output ?virtual_os ?image ~path cfg prog consume =
  let execute () = Felt.with_temporary_slots (fun () ->
      let r = initialize ?virtual_os ?image ~proof:false ~record_trace:false ~path cfg prog in
      Runner.run_until_end r;
      Finalize.end_run r ~secure:cfg.Runner.secure_run ~allow_missing:cfg.allow_missing_builtins;
      consume r) in
  match image with
  | None -> execute ()
  | Some _ ->
      let previous = batch_pedersen_cache true in
      Fun.protect execute ~finally:(fun () -> ignore (batch_pedersen_cache previous))

let run_output_file ?virtual_os ?image ~path cfg prog =
  with_output ?virtual_os ?image ~path cfg prog Artifacts.output_lines

let run_output_to_channel ?virtual_os ?image ~path cfg prog channel =
  with_output ?virtual_os ?image ~path cfg prog (Artifacts.write_output channel)
