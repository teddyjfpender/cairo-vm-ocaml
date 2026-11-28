open Errors
open Hintrt

let pack base per values =
  let rec loop count factor word packed = function
    | [] -> List.rev (if count = 0 then packed else Felt.of_z word :: packed)
    | v :: tail ->
        let word = Z.(add word (mul factor v)) in
        if count + 1 = per then loop 0 Z.one Z.zero (Felt.of_z word :: packed) tail
        else loop (count+1) (Z.mul factor base) word packed tail in
  loop 0 Z.one Z.zero [] values

let compress data =
  let n = List.length data in
  if n >= 1 lsl 20 then fail "State diff exceeds compression limit";
  let widths = [|252;125;83;62;31;15|] and counts = Array.make 6 0 in
  let buckets = Array.make 6 [] and seen = Felt_tbl.create n in
  let repeats = ref [] and indices = ref [] in
  List.iter (fun value ->
      if not (Felt.is_felt value) then fail "Expected felt in state diff";
      match Felt_tbl.find_opt seen value with
      | Some pos -> repeats := pos :: !repeats; indices := 6 :: !indices
      | None ->
          let z = Felt.to_z value in
          let bits = Z.numbits z in
          let rec bucket i = if bits <= widths.(i) then i else bucket (i-1) in
          let i = bucket 5 in
          Felt_tbl.add seen value (i,counts.(i));
          counts.(i) <- counts.(i)+1; buckets.(i) <- z :: buckets.(i);
          indices := i :: !indices) data;
  let pack_indices base seq =
    let bits = max 1 (Z.numbits (Z.of_int (max 0 (base-1)))) in
    pack (Z.of_int base) (251 / bits) (List.map Z.of_int seq) in
  let offsets = Array.make 6 0 in
  for i = 1 to 5 do offsets.(i) <- offsets.(i-1) + counts.(i-1) done;
  let unique = Array.to_list (Array.mapi (fun i bucket ->
      let bits = widths.(i) in pack (Z.shift_left Z.one bits) (max 1 (251 / bits)) (List.rev bucket)) buckets) in
  let pointers = List.rev_map (fun (i,j) -> offsets.(i)+j) !repeats in
  List.concat (pack_indices (1 lsl 20) ([0;n] @ Array.to_list counts @ [List.length pointers])
    :: unique @ [pack_indices (Felt_tbl.length seen) pointers; pack_indices 7 (List.rev !indices)])

(* The sequencer salts each compressed state diff with fresh OS entropy.
   Derive independent symmetric and private keys with its SHA-256 labels. *)
let generate_keys c vm =
  let first = get_ptr vm c "compressed_start" in
  let count = Felt.to_nat (Vm.value_sub (get_ptr vm c "compressed_end") first) in
  let n_keys = Felt.to_nat (get_felt vm c "n_keys") in
  if count < 0 then fail "Invalid compressed state diff range";
  if n_keys < 0 || n_keys > 256 then fail "Too many state diff encryption recipients";
  let entropy = In_channel.with_open_bin "/dev/urandom" (fun ic -> really_input_string ic 32) in
  let input = Buffer.create 128 in
  Buffer.add_string input entropy;
  for i = 0 to count-1 do
    let word = mem_at vm first i in
    if not (Felt.is_felt word) then fail "Expected field element in compressed state diff";
    Buffer.add_string input (Ec.be32 (Felt.to_z word))
  done;
  let seed = Sha256.digest (Buffer.contents input) in
  set_val vm c "symmetric_key" (Felt.of_z (z_of_be (Sha256.digest (seed ^ "SYM"))));
  let keys = List.init n_keys (fun i ->
      let hash = Sha256.digest (seed ^ "PRIV" ^ String.make 1 (Char.chr i)) in
      Felt.of_z (z_of_be (String.sub hash 0 31))) in
  set_val vm c "sn_private_keys" (gen_arg vm keys)

(* The older two-field ABI has no proof-facts segment. Allocating even an
   empty one changes relocated memory, PIE metadata and memory-hole counts. *)
let has_tx_proof_facts c =
  let name = "starkware.starknet.core.os.output.OsCarriedOutputs" in
  match Hashtbl.find_opt c.prog.P.identifiers name with
  | Some id -> List.mem_assoc "tx_proof_facts" id.P.i_members
  | None -> fail "Missing OS output structure %s" name

let register ?(pages_enabled=ref false) ~set_pages reg =
  reg "GenerateKeysUsingSha256Hash" generate_keys;
  let segment vm temp = Felt.reloc ((if temp then Vm.add_temp_segment else Vm.add_segment) vm) 0 in
  let bool = function v when Felt.equal v Felt.zero -> false
    | v when Felt.equal v Felt.one -> true | _ -> fail "Expected OS Boolean" in
  reg "SetNUpdatesSmall" (fun c vm ->
      set_val vm c "is_n_updates_small" (of_bool (Z.lt (get_z vm c "n_updates") (const_z c "N_UPDATES_SMALL_PACKING_BOUND"))));
  reg "AllocateSegmentsForMessages" (fun c vm ->
      let to_l1 = segment vm true in
      let to_l2 = segment vm true in
      let fields = if has_tx_proof_facts c then [to_l1; to_l2; segment vm false] else [to_l1; to_l2] in
      set_val vm c "initial_carried_outputs" (gen_arg vm fields));
  reg "ConfigureKzgManager" (fun _ _ -> pages_enabled := true);
  reg "SetProofFactTopology" (fun c vm -> if !pages_enabled then begin
      let start = get_ptr vm c "da_start" and stop = get_ptr vm c "output_ptr" in
      let length = Felt.to_nat (Vm.value_sub stop start) in
      let n = (length + 3799) / 3800 in
      let pages = List.init n (fun i -> let offset = i*3800 in
          i+1, (Felt.roff start + offset, min 3800 (length-offset))) in
      set_pages pages ["gps_fact_topology", [1+n;n;0;2]]
    end);
  reg "SetStateUpdatesStart" (fun c vm ->
      let kzg = get_felt vm c "use_kzg_da" in set c.scopes "use_kzg_da" (Value kzg);
      let compress = bool (get_felt vm c "compress_state_updates") in
      set_val vm c "state_updates_start" (segment vm (not (bool kzg || compress))));
  let kzg c = match var c.scopes "use_kzg_da" with Value v -> bool v | _ -> fail "Invalid DA mode" in
  reg "SetCompressedStart" (fun c vm ->
      set_val vm c "compressed_start" (segment vm (not (kzg c) && Felt.equal (get_felt vm c "n_keys") Felt.zero)));
  reg "SetEncryptedStart" (fun c vm -> set_val vm c "encrypted_start" (segment vm (not (kzg c))));
  reg "CompressionHint" (fun c vm ->
      let start = get_ptr vm c "data_start" in
      let size = Felt.to_nat (Vm.value_sub (get_ptr vm c "data_end") start) in
      if size >= 1 lsl 20 then fail "State diff exceeds compression limit";
      write_arg vm (get_ptr vm c "compressed_dst") (compress (List.init size (mem_at vm start))));
  reg "DictionaryFromBucket" (fun c _ ->
      let dict = Felt_tbl.create 7 in
      for i = 0 to 6 do Felt_tbl.add dict (Felt.small i) Felt.zero done;
      set c.scopes "initial_dict" (Initial_dict dict));
  reg "GetPrevOffset" (fun c vm ->
      let tracker = Dict.get_tracker c.scopes (get_ptr vm c "dict_ptr") in
      set_val vm c "prev_offset" (Dict.dict_lookup tracker (get_val vm c "bucket_index")));
  reg "SetDecompressedDst" (fun c vm ->
      let base = get_z vm c "elm_bound" in
      if Z.equal base Z.zero then fail "Zero decompression bound";
      write_arg vm (get_ptr vm c "decompressed_dst") [Felt.of_z (Z.rem (get_z vm c "packed_felt") base)])
