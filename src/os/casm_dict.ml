open Errors
open Hintrt

let compile name ~arg ~ptr ~put scopes =
  let dicts () = match var_opt scopes "dict_manager_exec_scope" with
    | Some (Casm_dicts t) -> t
    | None -> let t = Int_tbl.create 4 in set scopes "dict_manager_exec_scope" (Casm_dicts t); t
    | _ -> fail "Invalid CASM dictionary manager" in
  let tracker p = match Int_tbl.find_opt (dicts ()) (Felt.rseg p) with
    | Some t -> t | None -> fail "Invalid CASM dictionary address" in
  let update xs = set scopes "dict_squash_exec_scope" (Casm_squash xs) in
  let current () = match var_opt scopes "dict_squash_exec_scope" with
    | Some (Casm_squash ((key, accesses) :: rest)) -> key, accesses, rest
    | _ -> fail "Empty CASM dictionary squash" in
  match name with
  | "AllocFelt252Dict" ->
      let arena = ptr "segment_arena_ptr" in
      (fun vm ->
        let arena = arena vm in
        let n = Felt.to_nat (mem_at vm arena (-2)) and infos = mem_at vm arena (-3) in
        let t = dicts () in
        let count = Int_tbl.length t in
        let seg = if count = 0 then Vm.add_segment vm else Vm.add_temp_segment vm in
        Int_tbl.add t seg (count, Felt_tbl.create 8);
        write_arg vm (Vm.reloc_add_felt infos (Felt.of_int (3*n))) [Felt.reloc seg 0])
  | "Felt252DictEntryInit" ->
      let dict = ptr "dict_ptr" and key = arg "key" in
      (fun vm -> let p = dict vm in
        let _, values = tracker p in
        write_arg vm (Vm.reloc_add_felt p Felt.one)
          [Option.value (Felt_tbl.find_opt values (key vm)) ~default:Felt.zero])
  | "Felt252DictEntryUpdate" ->
      let dict = ptr "dict_ptr" and value = ptr "value" in
      (fun vm -> let p = dict vm in
        Felt_tbl.replace (snd (tracker p)) (mem_at vm p (-3)) (value vm))
  | "GetSegmentArenaIndex" ->
      let dict = ptr "dict_end_ptr" and index = put "dict_index" in
      (fun vm -> index vm (Felt.of_int (fst (tracker (dict vm)))))
  | "InitSquashData" ->
      let dict = ptr "dict_accesses" and count = arg "n_accesses" in
      let big = put "big_keys" and first = put "first_key" in
      (fun vm ->
        let p = dict vm and n = Felt.to_nat (count vm) in
        let groups = Felt_tbl.create 8 in
        let large = ref false in
        for i = n-1 downto 0 do
          let key = mem_at vm p (3*i) in
          if not (Felt.is_felt key) then fail "Expected felt dictionary key";
          if Felt.bits key > 128 then large := true;
          Felt_tbl.replace groups key (i :: Option.value (Felt_tbl.find_opt groups key) ~default:[])
        done;
        let keys = Felt_tbl.fold (fun k xs all -> (k,xs)::all) groups []
          |> List.sort (fun (x,_) (y,_) -> Felt.compare x y) in
        update keys;
        let key,_,_ = current () in big vm (of_bool !large); first vm key)
  | "GetCurrentAccessIndex" ->
      let rc = ptr "range_check_ptr" in
      (fun vm -> match current () with
        | _, i :: _, _ -> write_arg vm (rc vm) [Felt.of_int i]
        | _ -> fail "Empty CASM access indices")
  | "ShouldSkipSquashLoop" | "ShouldContinueSquashLoop" ->
      let skip = name = "ShouldSkipSquashLoop" in
      let dst = put (if skip then "should_skip_loop" else "should_continue") in
      (fun vm -> let _,indices,_ = current () in
        let more = match indices with _::_::_ -> true | _ -> false in
        dst vm (of_bool (more <> skip)))
  | "GetCurrentAccessDelta" ->
      let dst = put "index_delta_minus1" in
      (fun vm -> match current () with
        | key, i :: (next :: _ as remaining), rest ->
            dst vm (Felt.of_int (next-i-1)); update ((key,remaining) :: rest)
        | _ -> fail "Missing next CASM access index")
  | "GetNextDictKey" ->
      let dst = put "next_key" in
      (fun vm -> match current () with
        | _, [_], ((key,_) :: _ as rest) -> update rest; dst vm key
        | _ -> fail "Missing next CASM dictionary key")
  | _ -> invalid_arg "Casm_dict.compile"
