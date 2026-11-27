open Errors
open Hintrt
module U = Yojson.Safe.Util

let ascii s =
  if String.length s > 31 || String.exists (fun c -> Char.code c > 127) s then
    fail "Block hash short string exceeds ASCII felt encoding";
  Felt.of_z (z_of_be s)

let hash_many fields =
  let absorb state x y =
    Felt.poseidon [|Felt.add state.(0) x; Felt.add state.(1) y; state.(2)|] in
  let rec pairs state = function
    | x :: y :: tail -> pairs (absorb state x y) tail
    | [x] -> (absorb state x Felt.one).(0)
    | [] -> (absorb state Felt.one Felt.zero).(0) in
  pairs [|Felt.zero; Felt.zero; Felt.zero|] fields

let register ~block ~felt reg =
  reg "IsBlockNumberInBlockHashBuffer" (fun c vm ->
      let oldest = Z.sub (get_z vm c "current_block_number") (const_z c "STORED_BLOCK_HASH_BUFFER") in
      set_val vm c "is_block_number_in_block_hash_buffer" (of_bool (Z.gt (get_z vm c "request_block_number") oldest)));
  reg "GetBlockHashes" (fun c vm ->
      let input = block () in
      let info = U.member "block_info" input and header = U.member "block_hash_commitments" input in
      set_val vm c "previous_block_hash" (felt (U.member "prev_block_hash" input));
      let fields = List.map (fun key -> felt (U.member key header))
          ["transaction_commitment"; "event_commitment"; "receipt_commitment";
           "state_diff_commitment"; "concatenated_counts"] in
      set_val vm c "header_commitments" (gen_arg vm fields);
      let version = U.to_string (U.member "starknet_version" info) in
      let parts = String.split_on_char '.' version |> List.map int_of_string in
      if parts < [0;13;4] then fail "Unsupported Starknet version for gas price hash";
      let on_chain = match U.member "starknet_version_override" input with
        | `Null -> version | j -> U.to_string j in
      set_val vm c "starknet_version" (ascii on_chain);
      let gas = U.member "gas_prices" info in
      let prices = List.concat_map (fun key ->
          List.map (fun unit -> felt (U.member key (U.member unit gas))) ["eth_gas_prices"; "strk_gas_prices"])
          ["l1_gas_price"; "l1_data_gas_price"; "l2_gas_price"] in
      set_val vm c "gas_prices_hash" (hash_many (ascii "STARKNET_GAS_PRICES0" :: prices)))
