(* Each block has independent transaction and execution-info cursors. The OS
   selects its call witnesses in the sequencer's depth-first execution order. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

type tx = { kind : string; version : Felt.t; body : Yojson.Safe.t; wrapper : Yojson.Safe.t }

let variant = function `Assoc [name, body] -> name, body | _ -> fail "Expected serialized transaction variant"

let decode felt serialized =
  let kind, outer = variant serialized in
  let kind, wrapper = if kind = "Account" then variant outer else kind, outer in
  let inner = U.member "tx" wrapper in
  let version, body = if kind = "L1Handler" then felt (U.member "version" inner), inner
    else let tag, body = variant inner in
      if String.length tag < 2 || tag.[0] <> 'V' then fail "Invalid transaction version";
      felt (`String (String.sub tag 1 (String.length tag - 1))), body in
  {kind; version; body; wrapper}

let pop item queue =
  match !queue with
  | head :: tail -> queue := tail; head
  | [] -> fail "End of OS %s iterator" item

let register ~calls:call_state ~block ~felt reg =
  let txs = ref [] and infos = ref [] and active = ref None and info = ref None in
  let calls = ref [] in
  let next_json ?projection name queue = Json_reader.from_string ?projection (U.to_string (pop name queue)) in
  let tx () = match !active with Some t -> t | None -> fail "Missing active OS transaction" in
  let tx_info () = match !info with Some i -> i | None -> fail "Missing active execution info" in
  let member key = U.member key (tx ()).body in
  let set_list c vm ptr size l =
    let values = List.map felt l in
    set_val vm c ptr (gen_arg vm values);
    set_val vm c size (Felt.small (List.length values)) in
  let entries key = U.to_list (member key) in
  let field id c vm = set_val vm c id (felt (member id)) in
  reg "RemainingGasGtMax" (fun c vm ->
      set_val vm c "remaining_gas_gt_max" (of_bool (Felt.compare (get_felt vm c "remaining_gas") (get_felt vm c "max_gas") > 0)));
  reg "InitialGeRequiredGas" (fun c vm ->
      set_val vm c "initial_ge_required_gas" (of_bool (Felt.compare (get_felt vm c "initial_gas") (get_felt vm c "required_gas") >= 0)));
  reg "IsRemainingGasLtInitialBudget" (fun c vm ->
      set_val vm c "is_remaining_gas_lt_initial_budget" (of_bool (Z.lt (get_z vm c "remaining_gas") (const_z c "ENTRY_POINT_INITIAL_BUDGET"))));
  reg "LoadNextTx" (fun c vm ->
      let t = decode felt (next_json "transaction" txs) in
      active := Some t;
      let name = match t.kind with "Invoke" -> "INVOKE_FUNCTION" | "Declare" -> "DECLARE"
        | "DeployAccount" -> "DEPLOY_ACCOUNT" | "L1Handler" -> "L1_HANDLER" | _ -> fail "Unknown transaction type" in
      set_val vm c "tx_type" (Os_block_hash.ascii name));
  Os_calls.register call_state ~felt ~next:(fun () -> pop "call info" calls) reg;
  let start () =
    if !info <> None then fail "Execution info already active";
    let i = next_json ~projection:Os_calls.execution_projection "transaction execution info" infos in
    info := Some i;
    let rec flatten call =
      call :: List.concat_map flatten (U.to_list (U.member "inner_calls" call)) in
    let roots = if (tx ()).kind = "DeployAccount" then ["execute_call_info";"validate_call_info"]
      else ["validate_call_info";"execute_call_info"] in
    calls := List.concat_map (fun k -> match U.member k i with `Null -> [] | v -> flatten v)
        (roots @ ["fee_transfer_call_info"]) in
  let finish () =
    ignore (tx_info ());
    if !calls <> [] then fail "Unconsumed calls in OS transaction";
    info := None in
  reg "StartTx" (fun _ _ -> start ());
  reg "EndTx" (fun _ _ -> finish ());
  reg "SkipTx" (fun _ _ -> start (); finish ());
  reg "ExitTx" (fun c vm -> ignore (get_ptr vm c "range_check_ptr"));
  reg "TxVersion" (fun c vm -> set_val vm c "tx_version" (tx ()).version);
  reg "ContractAddress" (fun c vm ->
      let t = tx () in
      let address = match t.kind with
        | "L1Handler" -> member "contract_address" | "DeployAccount" -> U.member "contract_address" t.wrapper
        | _ -> member "sender_address" in
      set_val vm c "contract_address" (felt address));
  reg "LoadTxNonceAccount" (field "nonce");
  reg "LoadTxNonceL1Handler" (field "nonce");
  reg "DeclareTxFields" (fun c vm ->
      if (tx ()).kind <> "Declare" || not (Felt.equal (tx ()).version (Felt.small 3)) then
        fail "Expected declare transaction version 3";
      field "sender_address" c vm;
      set_list c vm "account_deployment_data" "account_deployment_data_size" (entries "account_deployment_data");
      set_val vm c "class_hash_ptr" (gen_arg vm [felt (member "class_hash")]);
      field "compiled_class_hash" c vm);
  reg "SetComponentHashes" (fun c vm ->
      if (tx ()).kind <> "Declare" then fail "Expected declare transaction";
      let hash = felt (member "class_hash") in
      let entries = U.to_assoc (U.member "declared_class_hash_to_component_hashes" (block ())) in
      let components = match List.find_opt (fun (k,_) -> Felt.equal (felt (`String k)) hash) entries with
        | Some (_,v) -> v | None -> fail "Missing declared class component hashes" in
      let fields = ["contract_class_version"; "external_functions_hash"; "l1_handlers_hash";
                    "constructors_hash"; "abi_hash"; "sierra_program_hash"] in
      set_val vm c "contract_class_component_hashes"
        (gen_arg vm (List.map (fun k -> felt (U.member k components)) fields)));
  reg "PrepareConstructorExecution" (fun c vm ->
      if (tx ()).kind <> "DeployAccount" then fail "Expected deploy-account transaction";
      field "contract_address_salt" c vm;
      field "class_hash" c vm;
      set_list c vm "constructor_calldata" "constructor_calldata_size" (entries "constructor_calldata"));
  reg "TxCalldata" (fun c vm ->
      let key = if (tx ()).kind = "DeployAccount" then "constructor_calldata" else "calldata" in
      set_list c vm "calldata" "calldata_size" (entries key));
  reg "TxEntryPointSelector" (field "entry_point_selector");
  reg "TxProofFacts" (fun c vm ->
      let facts = match member "proof_facts" with `Null -> [] | l -> U.to_list l in
      set_list c vm "proof_facts" "proof_facts_size" facts);
  reg "TxAccountDeploymentData" (fun c vm ->
      set_list c vm "account_deployment_data" "account_deployment_data_size" (entries "account_deployment_data"));
  reg "GenSignatureArg" (fun c vm -> set_list c vm "signature_start" "signature_len" (entries "signature"));
  reg "IsReverted" (fun c vm -> set_val vm c "is_reverted" (of_bool (U.member "revert_error" (tx_info ()) <> `Null)));
  reg "LoadActualFee" (fun c vm -> set_val vm c "low_actual_fee" (felt (U.member "actual_fee" (tx_info ()))));
  reg "AssertTransactionHash" (fun c vm ->
      if not (Felt.equal (get_felt vm c "transaction_hash") (felt (U.member "tx_hash" (tx ()).wrapper))) then
        fail "Inconsistent transaction hash");
  reg "LoadCommonTxFields" (fun c vm ->
      set_list c vm "paymaster_data" "paymaster_data_length" (entries "paymaster_data");
      let bounds = member "resource_bounds" in
      let resources = List.concat_map (fun key ->
          let b = U.member key bounds in
          [Os_block_hash.ascii key; felt (U.member "max_amount" b); felt (U.member "max_price_per_unit" b)])
          ["L1_GAS";"L2_GAS";"L1_DATA"] in
      set_val vm c "resource_bounds" (gen_arg vm resources);
      field "tip" c vm;
      List.iter (fun k -> set_val vm c k (match U.to_string (member k) with
          | "L1" -> Felt.zero | "L2" -> Felt.one | _ -> fail "Invalid transaction DA mode"))
        ["nonce_data_availability_mode"; "fee_data_availability_mode"]);
  fun () ->
    txs := U.to_list (U.member "transactions" (block ()));
    infos := U.to_list (U.member "tx_execution_infos" (block ()));
    active := None; info := None; calls := []
