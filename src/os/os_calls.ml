open Errors
open Hintrt
module U = Yojson.Safe.Util

type call = {
  witness : Yojson.Safe.t;
  execution_info : Felt.t;
  deprecated_tx_info : Felt.t;
  inner : Yojson.Safe.t list ref;
  deployed : Yojson.Safe.t list ref;
  reads : Yojson.Safe.t list ref;
  class_reads : Yojson.Safe.t list ref;
  block_reads : Yojson.Safe.t list ref;
}

type t = { mutable current : call option; mutable syscall_ptr : Felt.t option }

let create () = {current=None; syscall_ptr=None}
let current s = match s.current with Some c -> c | None -> fail "Missing OS call info"
let pop kind values = match !values with
  | [] -> fail "End of OS %s iterator" kind | v :: rest -> values := rest; v

let register s ~felt ~next reg =
  let exit () =
    let c = current s in
    if List.exists (fun xs -> !xs <> []) [c.inner;c.deployed;c.reads;c.class_reads;c.block_reads] then
      fail "Unconsumed call execution witnesses";
    s.current <- None in
  let logged = ref [] in
  let selector c vm = ignore (get_ptr vm c "range_check_ptr"); get_felt vm c "selector" in
  let enter_syscall c vm = logged := selector c vm :: !logged in
  reg "LogEnterSyscall" enter_syscall;
  reg "OsLoggerEnterSyscallPrepareExitSyscall" enter_syscall;
  reg "OsLoggerExitSyscall" (fun c vm ->
      if not (Felt.equal (pop "logged syscalls" logged) (selector c vm)) then fail "Unexpected syscall exit");
  let check_response prefix c vm =
    let first = get_member vm c "response" [prefix ^ "retdata_start"] in
    let last = get_member vm c "response" [prefix ^ "retdata_end"] in
    let n = Felt.to_nat (get_felt vm c "retdata_size") in
    if not (Felt.is_reloc first && Felt.is_reloc last) || n < 0 ||
       not (Felt.equal (Vm.value_sub last first) (Felt.small n)) then fail "Inconsistent retdata size";
    let data = get_val vm c "retdata" in
    if n > 0 && not (Felt.is_reloc data) then fail "Invalid retdata pointer";
    for i = 0 to n - 1 do
      if not (Felt.equal (mem_at vm first i) (mem_at vm data i)) then fail "Inconsistent retdata"
    done;
    if not (Felt.equal data Felt.zero) then begin
      if not (Felt.is_reloc data) then fail "Invalid retdata pointer";
      let rec copy i =
        let v = Vm.get vm (Felt.rseg last) (Felt.roff last + i) in
        if v <> Felt.empty then begin
          Vm.write_checked vm (Felt.rseg data) (Felt.roff data + n + i) v;
          copy (i+1)
        end in
      copy 0
    end in
  reg "CheckNewCallContractResponse" (check_response "");
  reg "CheckNewDeployResponse" (check_response "constructor_");
  reg "CheckRetdataForDebug" (fun c vm ->
      ignore (get_ptr vm c "retdata");
      if Felt.to_nat (get_felt vm c "retdata_size") < 0 then fail "Invalid retdata length");
  reg "EnterCall" (fun c vm ->
      if Option.is_some s.current then fail "OS call already active";
      let witness = next () in
      let storage = U.member "storage_access_tracker" witness in
      let values k = ref (U.to_list (U.member k storage)) in
      let inner = U.to_list (U.member "inner_calls" witness) in
      let deployed = List.filter_map (fun i ->
          let call = U.member "call" i in
          if U.member "entry_point_type" call = `String "CONSTRUCTOR" then Some (U.member "storage_address" call) else None) inner in
      s.current <- Some {witness; execution_info=get_member vm c "execution_context" ["execution_info"];
        deprecated_tx_info=get_member vm c "execution_context" ["deprecated_tx_info"]; inner=ref inner;
        deployed=ref deployed; reads=values "storage_read_values"; class_reads=values "read_class_hash_values";
        block_reads=values "read_block_hash_values"});
  reg "ExitCall" (fun _ _ -> exit ());
  reg "EnterScopeSyscallHandler" (fun c _ -> enter c.scopes ["deprecated_syscalls", Value Felt.zero]);
  reg "EnterScopeDeprecatedSyscallHandler" (fun c _ -> enter c.scopes ["deprecated_syscalls", Value Felt.one]);
  reg "SetSyscallPtr" (fun c vm ->
      if var_opt c.scopes "deprecated_syscalls" = Some (Value Felt.one) then fail "Expected modern syscall handler";
      s.syscall_ptr <- Some (get_ptr vm c "syscall_ptr"));
  let mode () = U.to_string (U.member "tracked_resource" (current s).witness) in
  reg "IsSierraGasMode" (fun c vm -> set_val vm c "is_sierra_gas_mode" (of_bool (mode () = "SierraGas")));
  reg "DebugExpectedInitialGas" (fun c vm ->
      let call = U.member "call" (current s).witness in
      if not (Felt.equal (felt (U.member "initial_gas" call)) (get_felt vm c "inner_remaining_gas")) then
        fail "Inconsistent initial contract gas");
  reg "CheckExecutionAndExitCall" (fun c vm ->
      let execution = U.member "execution" (current s).witness in
      let gas = felt (U.member "gas_consumed" execution) in
      let actual = Felt.sub (get_felt vm c "remaining_gas") (get_member vm c "entry_point_return_values" ["gas_builtin"]) in
      let valid = if mode () = "SierraGas" then Felt.equal actual (Felt.sub gas (Felt.of_z (const_z c "ENTRY_POINT_INITIAL_BUDGET")))
        else Felt.equal gas Felt.zero in
      if not valid then fail "Inconsistent predicted contract gas";
      let stop = get_member vm c "entry_point_return_values" ["syscall_ptr"] in
      if s.syscall_ptr <> Some stop then fail "Inconsistent syscall end pointer";
      s.syscall_ptr <- None; exit ())
