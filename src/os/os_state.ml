(* Blockifier's serialized initial reads seed each block's cached state. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

let state_entry c vm key =
    let tracker = Dict.get_tracker c.scopes (get_ptr vm c "contract_state_changes") in
    set_val vm c "state_entry" (Dict.dict_lookup tracker key)

let register ~block ~felt reg =
  let initial () = U.member "initial_reads" (block ()) in
  let mapping reads field =
    let entries = U.to_assoc (U.member field reads) in
    let table = Felt_tbl.create (List.length entries) in
    List.iter (fun (key, value) -> Felt_tbl.replace table (felt (`String key)) (felt value)) entries;
    table in
  let lookup table field addr =
    match Felt_tbl.find_opt table addr with
    | Some v -> v
    | None -> fail "Missing initial %s for contract %s" field (Felt.to_string addr) in
  reg "GetBlockHashMapping" (fun c vm -> state_entry c vm (Felt.of_z (const_z c "BLOCK_HASH_CONTRACT_ADDRESS")));
  reg "GetContractAddressStateEntry" (fun c vm -> state_entry c vm (get_felt vm c "contract_address"));
  reg "SetStateEntryToAccountContractAddress" (fun c vm ->
      state_entry c vm (get_member vm c "tx_info" ["account_contract_address"]));
  reg "GetOldBlockNumberAndHash" (fun c vm ->
      match U.member "old_block_number_and_hash" (block ()) with
      | `List [n;hash] when Felt.equal (get_felt vm c "old_block_number") (felt n) ->
          set_val vm c "old_block_hash" (felt hash)
      | _ -> fail "Inconsistent old block number");
  reg "CheckBlockHashConsistency" (fun c vm ->
      if not (Felt.equal (get_felt vm c "block_hash") (felt (U.member "new_block_hash" (block ())))) then
        fail "Inconsistent calculated block hash");
  reg "InitializeStateChanges" (fun c vm ->
      let reads = initial () in
      let nonces = mapping reads "nonces" and classes = mapping reads "class_hashes" in
      let addresses = Felt_tbl.fold (fun addr _ xs -> addr :: xs) in
      let storage = U.to_assoc (U.member "storage" reads)
          |> List.filter_map (fun (addr, keys) ->
              if U.to_assoc keys = [] then None else Some (felt (`String addr))) in
      let all = List.sort_uniq Felt.compare (addresses nonces (addresses classes storage)) in
      let entries = Felt_tbl.create (List.length all) in
      List.iter (fun addr ->
          let nonce = lookup nonces "nonce" addr and hash = lookup classes "class hash" addr in
          let storage = Felt.reloc (Vm.add_segment vm) 0 in
          Felt_tbl.add entries addr (gen_arg vm [hash; storage; nonce])) all;
      set c.scopes "initial_dict" (Initial_dict entries));
  reg "InitializeClassHashes" (fun c _ ->
      set c.scopes "initial_dict" (Initial_dict (mapping (initial ()) "compiled_class_hashes")));
  reg "OsInputTransactions" (fun c vm ->
      let txs = U.to_list (U.member "transactions" (block ())) in
      set_val vm c "n_txs" (Felt.small (List.length txs)));
  reg "EnterScopeExecuteTransactionsInner" (fun c _ ->
      enter c.scopes ["__dict_manager", var c.scopes "__dict_manager"]);
  reg "LogRemainingTxs" (fun c vm -> ignore (get_felt vm c "n_txs"));
  reg "FillHolesInRc96Segment" (fun c vm ->
      let ptr = get_ptr vm c "range_check96_ptr" in
      let seg = Felt.rseg ptr in
      for i = 0 to Felt.roff ptr - 1 do
        if Vm.read vm seg i = Felt.empty then Vm.write vm seg i Felt.zero
      done);
  reg "GuessBlockInfo" (fun c vm ->
      let info = U.member "block_info" (block ()) in
      let fields = List.map (fun key -> felt (U.member key info))
          ["block_number"; "block_timestamp"; "sequencer_address"] in
      set_val vm c "block_info" (gen_arg vm fields))
