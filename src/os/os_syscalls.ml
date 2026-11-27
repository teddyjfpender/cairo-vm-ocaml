open Errors
open Hintrt
module U = Yojson.Safe.Util

let execution_info vm ctx (call : Os_calls.call) =
  let src = call.execution_info in
  let prefix = "starkware.starknet.common.new_syscalls." in
  let offset ty field = member_offset ctx (prefix ^ ty) field in
  let tx_slot = offset "ExecutionInfo" "tx_info" in
  let tx = mem_at vm src tx_slot in
  let get field = mem_at vm tx (offset "TxInfo" field) in
  if not (Felt.equal (get "version") (Felt.small 3)) then src else
  let class_hash = Pie_file.z_of_json (U.member "class_hash" (U.member "call" call.witness)) in
  let member list =
    let rec find i = i >= 0 && (Felt.equal (Felt.of_z class_hash)
        (Felt.of_z (const_z ctx (list ^ "_" ^ string_of_int i))) || find (i-1)) in
    find (Z.to_int (const_z ctx (list ^ "_LEN")) - 1) in
  let exclude = member "DATA_GAS_ACCOUNTS" in
  let v1 = member "V1_BOUND_ACCOUNTS_CAIRO1" &&
    Felt.compare (get "tip") (Felt.of_z (const_z ctx "V1_BOUND_ACCOUNTS_MAX_TIP")) <= 0 in
  if not (exclude || v1) then src else begin
    let fresh = Felt.reloc (Vm.add_segment vm) 0 in
    let copy ty ptr =
      let id = Hashtbl.find ctx.prog.Program.identifiers (prefix ^ ty) in
      Array.of_list (read_range vm ptr (List.length id.i_members)) in
    let fields = copy "TxInfo" tx in
    if v1 then fields.(offset "TxInfo" "version") <- Felt.one;
    if exclude then begin
      let start = get "resource_bounds_start" and stop = get "resource_bounds_end" in
      if not (Felt.equal (Vm.value_sub stop start) (Felt.small 9)) then fail "Invalid resource bounds span";
      fields.(offset "TxInfo" "resource_bounds_end") <- Vm.reloc_add_felt stop (Felt.small (-3))
    end;
    let out = copy "ExecutionInfo" src in
    out.(tx_slot) <- gen_arg vm (Array.to_list fields);
    write_arg vm fresh (Array.to_list out); fresh
  end

let run state ctx vm ptr =
  let open Os_calls in
  if state.syscall_ptr <> Some ptr then fail "Unexpected CASM syscall pointer";
  let at n = mem_at vm ptr n in
  let integer n = let v = at n in if not (Felt.is_felt v) then fail "Expected syscall felt"; v in
  let name_of x =
    let le = Z.to_bits (Felt.to_z x) in
    let len = ref (String.length le) in
    while !len > 0 && le.[!len-1] = '\000' do decr len done;
    String.init !len (fun i -> le.[!len-1-i]) in
  let name = name_of (integer 0) and gas = integer 1 in
  let span n =
    let start = at n and stop = at (n+1) in
    if not (Felt.is_reloc start && Felt.is_reloc stop) then fail "Expected syscall span";
    let count = Felt.to_nat (Vm.value_sub stop start) in
    if count < 0 then fail "Invalid syscall span";
    for i = 0 to count-1 do
      if not (Felt.is_felt (mem_at vm start i)) then fail "Invalid syscall array element"
    done in
  let call = current state in
  let as_felt json = Felt.of_z (Pie_file.z_of_json json) in
  let array temp values =
    let base = Felt.reloc ((if temp then Vm.add_temp_segment else Vm.add_segment) vm) 0 in
    write_arg vm base values;
    [base; Vm.reloc_add_felt base (Felt.small (List.length values))] in
  let success values gas = gas,Felt.zero,values in
  let units, cost, response =
    match name with
    | "GetExecutionInfo" -> 2,"GET_EXECUTION_INFO", (fun gas -> success [execution_info vm ctx call] gas)
    | "EmitEvent" ->
        span 2; span 4; 6,"EMIT_EVENT",(fun gas -> success [] gas)
    | "StorageRead" | "StorageWrite" ->
        if not (Felt.equal (integer 2) Felt.zero) || Felt.bits (integer 3) > 251 then fail "Invalid storage request";
        if name = "StorageWrite" then begin ignore (integer 4); 5,"STORAGE_WRITE",(fun gas -> success [] gas) end
        else 4,"STORAGE_READ",(fun gas -> success [as_felt (pop "storage reads" call.reads)] gas)
    | "CallContract" | "LibraryCall" ->
        ignore (integer 2); ignore (integer 3); span 4;
        6,(if name = "CallContract" then "CALL_CONTRACT" else "LIBRARY_CALL"),(fun gas ->
          let inner = U.member "execution" (pop "inner calls" call.inner) in
          let consumed = as_felt (U.member "gas_consumed" inner) in
          if Felt.compare gas consumed < 0 then fail "Inner call gas exceeds remaining gas";
          let gas = Felt.sub gas consumed and failed = U.to_bool (U.member "failed" inner) in
          let values = List.map as_felt (U.to_list (U.member "retdata" inner)) in
          let values = if failed then values @ [Os_block_hash.ascii "ENTRYPOINT_FAILED"] else values in
          gas,of_bool failed,array true values)
    | _ -> fail "Unsupported OS syscall %s" name in
  let required = Z.sub (const_z ctx (cost ^ "_GAS_COST")) (const_z ctx "SYSCALL_BASE_GAS_COST") in
  let gas,failed,values =
    if Z.lt (Felt.to_z gas) required then gas,Felt.one,array false [Os_block_hash.ascii "Out of gas"]
    else response (Felt.sub gas (Felt.of_z required)) in
  let out = gas :: failed :: values in
  write_arg vm (Vm.reloc_add_felt ptr (Felt.small units)) out;
  state.syscall_ptr <- Some (Vm.reloc_add_felt ptr (Felt.small (units + List.length out)))

let register_deprecated calls ~felt reg =
  let register name selector respond =
    let code = "syscall_handler." ^ name ^ "(segments=segments, syscall_ptr=ids.syscall_ptr)" in
    reg code (fun c vm ->
        if var_opt c.scopes "deprecated_syscalls" <> Some (Value Felt.one) then
          fail "Expected deprecated syscall handler";
        let ptr = get_ptr vm c "syscall_ptr" in
        if not (Felt.equal (mem_at vm ptr 0) (Os_block_hash.ascii selector)) then
          fail "Unexpected deprecated syscall selector";
        respond (Os_calls.current calls) vm ptr) in
  let integer vm ptr n =
    let v = mem_at vm ptr n in
    if not (Felt.is_felt v) then fail "Expected deprecated syscall integer";
    v in
  let key vm ptr =
    if Felt.bits (integer vm ptr 1) > 251 then fail "Invalid storage key" in
  let result vm ptr n values = write_arg vm (Vm.reloc_add_felt ptr (Felt.small n)) values in
  register "storage_write" "StorageWrite" (fun _ vm ptr -> key vm ptr; ignore (integer vm ptr 2));
  register "storage_read" "StorageRead" (fun call vm ptr ->
      key vm ptr; result vm ptr 2 [felt (Os_calls.pop "storage reads" call.reads)]);
  let address name selector field = register name selector (fun call vm ptr ->
      result vm ptr 1 [felt (U.member field (U.member "call" call.witness))]) in
  address "get_contract_address" "GetContractAddress" "storage_address";
  address "get_caller_address" "GetCallerAddress" "caller_address"
