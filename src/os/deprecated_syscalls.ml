(* Cairo 0 syscall requests use a fixed word layout and consume their
   witnesses from the current blockifier call in execution order. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

let register ~os_program calls ~felt reg =
  let register name selector respond =
    let code = "syscall_handler." ^ name ^ "(segments=segments, syscall_ptr=ids.syscall_ptr)" in
    reg code (fun c ->
        let schema = { c with prog = os_program; constants = [] } in
        fun vm ->
        if var_opt c.scopes "deprecated_syscalls" <> Some (Value Felt.one) then
          fail "Expected deprecated syscall handler";
        let ptr = get_ptr vm c "syscall_ptr" in
        if not (Felt.equal (mem_at vm ptr 0) (Os_block_hash.ascii selector)) then
          fail "Unexpected deprecated syscall selector";
        respond schema (Os_calls.current calls) vm ptr) in
  let integer vm ptr n =
    let v = mem_at vm ptr n in
    if not (Felt.is_felt v) then fail "Expected deprecated syscall integer";
    v in
  let key vm ptr =
    if Felt.bits (integer vm ptr 1) > 251 then fail "Invalid storage key" in
  let result vm ptr n values = write_arg vm (Vm.reloc_add_felt ptr (Felt.small n)) values in
  register "storage_write" "StorageWrite" (fun _ _ vm ptr -> key vm ptr; ignore (integer vm ptr 2));
  register "storage_read" "StorageRead" (fun _ call vm ptr ->
      key vm ptr; result vm ptr 2 [felt (Os_calls.pop "storage reads" call.reads)]);
  let address name selector field = register name selector (fun _ call vm ptr ->
      result vm ptr 1 [felt (U.member field (U.member "call" call.witness))]) in
  address "get_contract_address" "GetContractAddress" "storage_address";
  address "get_caller_address" "GetCallerAddress" "caller_address";
  let member c vm ptr ty field = mem_at vm ptr (member_offset c ty field) in
  let modern = "starkware.starknet.common.new_syscalls." in
  let old_tx = "starkware.starknet.common.syscalls.TxInfo" in
  let block_field name selector field bound =
    register name selector (fun c call vm ptr ->
        let block = member c vm call.execution_info (modern ^ "ExecutionInfo") "block_info" in
        let v = member c vm block (modern ^ "BlockInfo") field in
        if not (Felt.is_felt v) || Felt.bits v > bound then fail "Invalid %s" field;
        result vm ptr 1 [v]) in
  block_field "get_block_number" "GetBlockNumber" "block_number" 64;
  block_field "get_block_timestamp" "GetBlockTimestamp" "block_timestamp" 64;
  block_field "get_sequencer_address" "GetSequencerAddress" "sequencer_address" 251;
  let tx_info c call vm =
    let ptr = call.Os_calls.deprecated_tx_info in
    let version = member c vm ptr old_tx "version" in
    if not (Felt.equal version (Felt.small 3)) then ptr else
      let hash = felt (U.member "class_hash" (U.member "call" call.witness)) in
      let n = Z.to_int (const_z c "V1_BOUND_ACCOUNTS_CAIRO0_LEN") in
      let rec bound i =
        i < n && (Felt.equal hash (Felt.of_z (const_z c ("V1_BOUND_ACCOUNTS_CAIRO0_" ^ string_of_int i))) || bound (i+1)) in
      let tx = member c vm call.execution_info (modern ^ "ExecutionInfo") "tx_info" in
      let tip = member c vm tx (modern ^ "TxInfo") "tip" in
      if not (bound 0) || Felt.compare tip (Felt.of_z (const_z c "V1_BOUND_ACCOUNTS_MAX_TIP")) > 0 then ptr else
        let id = Hashtbl.find c.prog.Program.identifiers old_tx in
        let fields = Array.of_list (read_range vm ptr (List.length id.i_members)) in
        fields.(member_offset c old_tx "version") <- Felt.one;
        gen_arg vm (Array.to_list fields) in
  register "get_tx_info" "GetTxInfo" (fun c call vm ptr -> result vm ptr 1 [tx_info c call vm]);
  register "get_tx_signature" "GetTxSignature" (fun c call vm ptr ->
      let tx = tx_info c call vm in
      result vm ptr 1 [member c vm tx old_tx "signature_len"; member c vm tx old_tx "signature"]);
  let span vm ptr index =
    let n = Felt.to_nat (integer vm ptr index) and data = mem_at vm ptr (index+1) in
    if n < 0 || not (Felt.is_reloc data) then fail "Expected deprecated syscall segment";
    for i = 0 to n-1 do ignore (integer vm data i) done in
  register "emit_event" "EmitEvent" (fun _ _ vm ptr -> span vm ptr 1; span vm ptr 3);
  register "send_message_to_l1" "SendMessageToL1" (fun _ _ vm ptr ->
      ignore (integer vm ptr 1); span vm ptr 2);
  register "replace_class" "ReplaceClass" (fun _ _ vm ptr -> ignore (integer vm ptr 1));
  let invoke name selector contract =
    register name selector (fun _ call vm ptr ->
        let target = integer vm ptr 1 in
        if contract && Felt.bits target > 251 then fail "Invalid deprecated call address";
        ignore (integer vm ptr 2); span vm ptr 3;
        let nested = Os_calls.pop "inner calls" call.inner in
        let execution = U.member "execution" nested in
        if U.to_bool (U.member "failed" execution) then fail "Unexpected reverted Cairo 0 call";
        let words = List.map felt (U.to_list (U.member "retdata" execution)) in
        let retdata = Felt.reloc (Vm.add_temp_segment vm) 0 in
        write_arg vm retdata words;
        result vm ptr 5 [Felt.small (List.length words); retdata]) in
  invoke "call_contract" "CallContract" true;
  invoke "delegate_call" "DelegateCall" true;
  invoke "delegate_l1_handler" "DelegateL1Handler" true;
  invoke "library_call" "LibraryCall" false;
  invoke "library_call_l1_handler" "LibraryCallL1Handler" false;
  register "deploy" "Deploy" (fun _ call vm ptr ->
      ignore (integer vm ptr 1); ignore (integer vm ptr 2); span vm ptr 3;
      let from_zero = integer vm ptr 5 in
      if from_zero <> Felt.zero && from_zero <> Felt.one then fail "Invalid deploy_from_zero";
      ignore (Os_calls.pop "inner calls" call.inner);
      result vm ptr 6 [felt (Os_calls.pop "deployed contracts" call.deployed); Felt.zero; Felt.zero])
