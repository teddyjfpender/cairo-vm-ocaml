(* Per-block cached storage and the cross-block pointers used by state squashing. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

let register ~block ~felt ~state_initialized reg =
  let pointers = Felt_tbl.create 16 and storage = Felt_tbl.create 16 in
  let reset block =
    Felt_tbl.clear storage;
    let reads = U.member "storage" (U.member "initial_reads" block) in
    List.iter (fun (addr, cells) ->
        let table = Felt_tbl.create 8 in
        List.iter (fun (key, value) ->
            Felt_tbl.replace table (felt (`String key)) (felt value)) (U.to_assoc cells);
        Felt_tbl.replace storage (felt (`String addr)) table) (U.to_assoc reads) in
  let const c key = Felt.of_z (const_z c key) in
  let addr c = const c "ALIAS_CONTRACT_ADDRESS" in
  let counter c = const c "ALIAS_COUNTER_STORAGE_KEY" in
  let cells address =
    match Felt_tbl.find_opt storage address with
    | Some t -> t
    | None -> let t = Felt_tbl.create 8 in Felt_tbl.add storage address t; t in
  let read address key =
    match Felt_tbl.find_opt (cells address) key with
    | Some v -> v | None -> fail "Missing initial storage at %s" (Felt.to_string key) in
  let put address key v = Felt_tbl.replace (cells address) key v in
  let get_ptrs vm addr =
    (* Rust's entry.or_insert allocates both default segments even on a hit. *)
    let entry = Felt.reloc (Vm.add_segment vm) 0 in
    let storage = Felt.reloc (Vm.add_segment vm) 0 in
    if state_initialized () then
      match Felt_tbl.find_opt pointers addr with
      | Some pair -> pair
      | None -> Felt_tbl.add pointers addr (entry, storage); entry, storage
    else entry, storage in
  let get_pointers c vm addr entry_name storage_name =
    let entry, storage = get_ptrs vm addr in
    set_val vm c entry_name entry; set_val vm c storage_name storage in
  let set_pointers c vm addr entry_name storage_name =
    if state_initialized () then
      Felt_tbl.replace pointers addr (get_ptr vm c entry_name, get_ptr vm c storage_name) in
  let storage_key c vm id path =
    let key = get_member vm c id path in
    if not (Felt.is_felt key) || Felt.bits key > 251 then fail "Invalid storage key";
    key in
  let write c vm id key_path =
    let address = get_felt vm c "contract_address" and key = storage_key c vm id key_path in
    set_val vm c "prev_value" (read address key);
    put address key (Felt.of_z (get_member_z vm c id ["value"]));
    Os_state.state_entry c vm address in
  let check c vm id path =
    let value = read (get_felt vm c "contract_address") (storage_key c vm id path) in
    if not (Felt.equal value (get_felt vm c "value")) then fail "Inconsistent contract storage read" in
  reg "WriteSyscallResultDeprecated" (fun c vm -> write c vm "syscall_ptr" ["address"]);
  reg "WriteSyscallResult" (fun c vm -> write c vm "request" ["key"]);
  reg "CacheContractStorageRequestKey" (fun c vm -> check c vm "request" ["key"]);
  reg "CacheContractStorageSyscallRequestAddress" (fun c vm -> check c vm "syscall_ptr" ["request";"address"]);
  reg "WriteOldBlockToStorage" (fun c vm ->
      put (const c "BLOCK_HASH_CONTRACT_ADDRESS") (get_felt vm c "old_block_number") (get_felt vm c "old_block_hash"));
  reg "EnterScopeWithAliases" (fun c _ ->
      enter c.scopes ["__dict_manager", var c.scopes "__dict_manager"]);
  reg "GuessAliasesContractStoragePtr" (fun c vm ->
      get_pointers c vm (addr c) "prev_aliases_state_entry" "squashed_aliases_storage_start");
  reg "UpdateAliasesContractToStoragePtr" (fun c vm ->
      set_pointers c vm (addr c) "new_aliases_state_entry" "squashed_aliases_storage_end");
  reg "LoadStoragePtrAndPrevState" (fun c vm ->
      get_pointers c vm (mem_at vm (get_ptr vm c "state_changes") 0)
        "squashed_prev_state" "squashed_storage_ptr");
  reg "UpdateContractAddrToStoragePtr" (fun c vm ->
      set_pointers c vm (mem_at vm (get_ptr vm c "state_changes") 0)
        "squashed_new_state" "squashed_storage_ptr_end");
  reg "ReadAliasCounter" (fun c vm -> set_val vm c "next_available_alias" (read (addr c) (counter c)));
  reg "InitializeAliasCounter" (fun c _ -> put (addr c) (counter c) (const c "INITIAL_AVAILABLE_ALIAS"));
  reg "UpdateAliasCounter" (fun c vm -> put (addr c) (counter c) (get_felt vm c "next_available_alias"));
  reg "ReadAliasFromKey" (fun c vm -> set_val vm c "prev_value" (read (addr c) (get_felt vm c "key")));
  reg "WriteNextAliasFromKey" (fun c vm -> put (addr c) (get_felt vm c "key") (get_felt vm c "next_available_alias"));
  reg "ContractAddressLeMaxForCompression" (fun c vm ->
      set_val vm c "contract_address_le_max_for_compression"
        (of_bool (Felt.compare (get_felt vm c "contract_address") (const c "MAX_NON_COMPRESSED_CONTRACT_ADDRESS") <= 0)));
  let small_key c vm =
    Felt.compare (get_felt vm c "key") (const c "MIN_VALUE_FOR_ALIAS_ALLOC") < 0 in
  reg "KeyLtMinAliasAllocValue" (fun c vm -> set_val vm c "key_lt_min_alias_alloc_value" (of_bool (small_key c vm)));
  reg "AssertKeyBigEnoughForAlias" (fun c vm -> if small_key c vm then fail "Key too small for alias allocation");
  fun () -> reset (block ())
