open Errors
open Hintrt
module U = Yojson.Safe.Util

let execution_info ctx =
  let prefix = "starkware.starknet.common.new_syscalls." in
  let offset ty field = member_offset ctx (prefix ^ ty) field in
  let tx_slot = offset "ExecutionInfo" "tx_info" and version_slot = offset "TxInfo" "version" in
  let class_set list =
    let n = Z.to_int (const_z ctx (list ^ "_LEN")) in
    let set = Felt_tbl.create n in
    for i = 0 to n-1 do
      Felt_tbl.add set (Felt.of_z (const_z ctx (list ^ "_" ^ string_of_int i))) ()
    done;
    set in
  let exclusions = lazy (class_set "DATA_GAS_ACCOUNTS", class_set "V1_BOUND_ACCOUNTS_CAIRO1") in
  fun vm (call : Os_calls.call) ->
  let src = call.execution_info in
  let tx = mem_at vm src tx_slot in
  let get field = mem_at vm tx (offset "TxInfo" field) in
  if not (Felt.equal (mem_at vm tx version_slot) (Felt.small 3)) then src else
  let class_hash = Felt.of_z (Pie_file.z_of_json (U.member "class_hash" (U.member "call" call.witness))) in
  let data_gas, v1_bound = Lazy.force exclusions in
  let exclude = Felt_tbl.mem data_gas class_hash in
  let v1 = Felt_tbl.mem v1_bound class_hash &&
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

let bind state ~block ~secp ctx =
  let info = lazy (execution_info ctx) in
  let costs = Hashtbl.create 16 in
  let required_cost name =
    match Hashtbl.find_opt costs name with
    | Some cost -> cost
    | None ->
        let cost = Z.sub (const_z ctx (name ^ "_GAS_COST")) (const_z ctx "SYSCALL_BASE_GAS_COST") in
        if Z.sign cost < 0 then fail "Invalid syscall gas cost";
        Hashtbl.add costs name cost; cost in
  let names = Felt_tbl.create 16 in
  List.iter (fun name -> Felt_tbl.add names (Os_block_hash.ascii name) name)
    ["GetExecutionInfo"; "GetClassHashAt"; "GetBlockHash"; "Keccak"; "EmitEvent"; "StorageRead"; "StorageWrite"; "SendMessageToL1";
     "ReplaceClass"; "Deploy"; "CallContract"; "LibraryCall"; "MetaTxV0"; "Sha256ProcessBlock"; "Sha512ProcessBlock"];
  List.iter (fun (name, _) -> Felt_tbl.add names (Os_block_hash.ascii name) name) Os_secp.selectors;
  fun vm ptr ->
  let open Os_calls in
  if state.syscall_ptr <> Some ptr then fail "Unexpected CASM syscall pointer";
  let at n = mem_at vm ptr n in
  let integer n = let v = at n in if not (Felt.is_felt v) then fail "Expected syscall felt"; v in
  let selector = integer 0 and gas = integer 1 in
  let name = match Felt_tbl.find_opt names selector with
    | Some name -> name | None -> fail "Unsupported OS syscall selector %s" (Felt.to_string selector) in
  if Felt.bits gas > 64 then fail "Syscall gas exceeds u64";
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
  let inner_result gas =
    let execution = U.member "execution" (pop "inner calls" call.inner) in
    let consumed = as_felt (U.member "gas_consumed" execution) in
    if Felt.compare gas consumed < 0 then fail "Inner call gas exceeds remaining gas";
    Felt.sub gas consumed, U.to_bool (U.member "failed" execution),
    List.map as_felt (U.to_list (U.member "retdata" execution)) in
  let variable_cost = ref Z.zero in
  let success values gas = gas,Felt.zero,values in
  let units, cost, response =
    match name with
    | "GetExecutionInfo" -> 2,"GET_EXECUTION_INFO", (fun gas -> success [(Lazy.force info) vm call] gas)
    | "GetClassHashAt" ->
        if Felt.bits (integer 2) > 251 then fail "Invalid contract address";
        3, "GET_CLASS_HASH_AT", (fun gas -> success [as_felt (pop "class hash reads" call.class_reads)] gas)
    | "GetBlockHash" ->
        let requested = integer 2 in
        if Felt.bits requested > 64 then fail "Block number exceeds u64";
        3, "GET_BLOCK_HASH", (fun gas ->
            let number = Pie_file.z_of_json (U.member "block_number" (U.member "block_info" (block ()))) in
            if Z.gt (Felt.to_z requested) (Z.sub number (const_z ctx "STORED_BLOCK_HASH_BUFFER")) then
              gas, Felt.one, array false [Os_block_hash.ascii "Block number out of range"]
            else success [as_felt (pop "block hash reads" call.block_reads)] gas)
    | "EmitEvent" ->
        span 2; span 4; 6,"EMIT_EVENT",(fun gas -> success [] gas)
    | "StorageRead" | "StorageWrite" ->
        if not (Felt.equal (integer 2) Felt.zero) || Felt.bits (integer 3) > 251 then fail "Invalid storage request";
        if name = "StorageWrite" then begin ignore (integer 4); 5,"STORAGE_WRITE",(fun gas -> success [] gas) end
        else 4,"STORAGE_READ",(fun gas -> success [as_felt (pop "storage reads" call.reads)] gas)
    | "Keccak" ->
        let first = at 2 and last = at 3 in
        if not (Felt.is_reloc first && Felt.is_reloc last) then fail "Expected Keccak input pointers";
        let length = Felt.to_nat (Vm.value_sub last first) in
        4, "KECCAK", (fun gas ->
            if length mod 17 <> 0 then gas, Felt.one, array false [Os_block_hash.ascii "Invalid input length"]
            else
              let cost = Z.mul (Z.of_int (length / 17)) (const_z ctx "KECCAK_ROUND_COST_GAS_COST") in
              if Z.lt (Felt.to_z gas) cost then gas, Felt.one, array false [Os_block_hash.ascii "Out of gas"]
              else begin
                let lanes = Bytes.make 200 '\000' in
                for i = 0 to length - 1 do
                  let pos = 8 * (i mod 17) in
                  let word = z_at vm first i in
                  if Z.numbits word > 64 then fail "Keccak word exceeds u64";
                  Bytes.set_int64_le lanes pos (Int64.logxor (Bytes.get_int64_le lanes pos) (Z.to_int64_unsigned word));
                  if i mod 17 = 16 then Felt.keccak_f_bytes lanes
                done;
                let half i = Felt.of_z (Z.of_bits (Bytes.sub_string lanes i 16)) in
                success [half 0; half 16] (Felt.sub gas (Felt.of_z cost))
              end)
    | "Sha256ProcessBlock" | "Sha512ProcessBlock" ->
        let state = at 2 and input = at 3 in
        let kind, cost = if name = "Sha256ProcessBlock" then Os_sha.Sha256, "SHA256_PROCESS_BLOCK"
          else Os_sha.Sha512, "SHA512_PROCESS_BLOCK" in
        4, cost, (fun gas -> success [Os_sha.process vm kind state input] gas)
    | "SendMessageToL1" ->
        ignore (integer 2); span 3;
        variable_cost := Z.mul (Felt.to_z (Vm.value_sub (at 4) (at 3))) (const_z ctx "SEND_MESSAGE_TO_L1_PAYLOAD_FACTOR_GAS_COST");
        5,"SEND_MESSAGE_TO_L1",(fun gas -> success [] gas)
    | "ReplaceClass" ->
        ignore (integer 2);
        3,"REPLACE_CLASS",(fun gas -> success [] gas)
    | "Deploy" ->
        ignore (integer 2); ignore (integer 3); span 4;
        let from_zero = integer 6 in
        if from_zero <> Felt.zero && from_zero <> Felt.one then fail "Invalid deploy_from_zero";
        variable_cost := Z.mul (Felt.to_z (Vm.value_sub (at 5) (at 4))) (const_z ctx "DEPLOY_CALLDATA_FACTOR_GAS_COST");
        7,"DEPLOY",(fun gas ->
          let address = as_felt (pop "deployed contracts" call.deployed) in
          let gas, failed, retdata = inner_result gas in
          let bounds = array true retdata in
          if failed then gas,Felt.one,array true retdata else success (address :: bounds) gas)
    | "CallContract" | "LibraryCall" | "MetaTxV0" ->
        let target = integer 2 and selector = integer 3 in
        if name <> "LibraryCall" && Felt.bits target > 251 then fail "Invalid contract address";
        span 4;
        let size, cost = match name with
          | "MetaTxV0" ->
              span 6;
              variable_cost := Z.mul (Felt.to_z (Vm.value_sub (at 5) (at 4)))
                  (const_z ctx "META_TX_V0_CALLDATA_FACTOR_GAS_COST");
              8, "META_TX_V0"
          | "CallContract" -> 6, "CALL_CONTRACT"
          | _ -> 6, "LIBRARY_CALL" in
        size,cost,(fun gas ->
          let execute = Z.equal (Felt.to_z selector) (const_z ctx "EXECUTE_ENTRY_POINT_SELECTOR") in
          if (name = "CallContract" && execute) || (name = "MetaTxV0" && not execute) then
            gas,Felt.one,array false [Os_block_hash.ascii "Invalid argument"]
          else
            let gas, failed, values = inner_result gas in
            let values = if failed then values @ [Os_block_hash.ascii "ENTRYPOINT_FAILED"] else values in
            gas,of_bool failed,array true values)
    | _ ->
        (match List.assoc_opt name Os_secp.selectors with
         | None -> fail "Unsupported OS syscall %s" name
         | Some (gas_cost, curve, op, size) ->
             size, gas_cost, (fun gas -> match Os_secp.execute secp vm curve op at with
                 | Ok values -> success values gas
                 | Error reason -> gas, Felt.one, array false [Os_block_hash.ascii reason])) in
  let required = Z.add !variable_cost (required_cost cost) in
  let gas,failed,values =
    if Z.lt (Felt.to_z gas) required then gas,Felt.one,array false [Os_block_hash.ascii "Out of gas"]
    else response (Felt.sub gas (Felt.of_z required)) in
  let out = gas :: failed :: values in
  write_arg vm (Vm.reloc_add_felt ptr (Felt.small units)) out;
  state.syscall_ptr <- Some (Vm.reloc_add_felt ptr (Felt.small (units + List.length out)))
