(* Dict manager, dict access and squash_dict hints (cairo-vm
   dict_hint_utils.rs, dict_manager.rs, squash_dict_utils.rs). *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

let dict_manager scopes =
  match var_opt scopes "__dict_manager" with
  | Some (Dict_manager m) -> m
  | _ ->
      let m = Int_tbl.create 8 in
      set scopes "__dict_manager" (Dict_manager m);
      m

let get_tracker scopes ptr =
  let m = match var_opt scopes "__dict_manager" with Some (Dict_manager m) -> m | _ -> fail "No dict manager" in
  if not (Felt.is_reloc ptr) then fail "dict_ptr is not a pointer";
  match Int_tbl.find_opt m (Felt.rseg ptr) with
  | None -> fail "Dict Error: No dict tracker found for segment %d" (Felt.rseg ptr)
  | Some t ->
      if t.current_ptr <> ptr then
        fail "Dict Error: Wrong dict pointer supplied. Got %s, expected %s." (value_to_string ptr) (value_to_string t.current_ptr);
      t

let dict_lookup t key =
  let change = match t.changes with None -> None | Some m -> Dict_changes.find_opt key m in
  match change with
  | Some v -> v
  | None ->
      (match Felt_tbl.find_opt t.data key with
       | Some v -> v
       | None -> match t.default with Some d -> d | None -> fail "Dict Error: no value found for key %s" (value_to_string key))

let dict_set t key value =
  match t.changes with
  | None -> Felt_tbl.replace t.data key value
  | Some m -> t.changes <- Some (Dict_changes.add key value m)

let dict_entries t =
  let h = Felt_tbl.copy t.data in
  Option.iter (Dict_changes.iter (Felt_tbl.replace h)) t.changes;
  Felt_tbl.fold (fun k v acc -> (k, v) :: acc) h []

let snapshot t =
  let changes = match t.changes with
    | Some m -> m
    | None -> t.changes <- Some Dict_changes.empty; Dict_changes.empty
  in
  t.data, changes

let add_tracker vm scopes data changes default =
  let m = dict_manager scopes in
  let s = add_segment vm in
  let ptr = Felt.reloc s 0 in
  Int_tbl.replace m s { data; changes; default; current_ptr = ptr };
  ptr

let new_dict vm scopes initial default =
  let data = Felt_tbl.create 16 in
  (match initial with Some h -> Felt_tbl.iter (fun k v -> Felt_tbl.replace data k v) h | None -> ());
  add_tracker vm scopes data None default

let from_snapshot vm scopes (data, changes) = add_tracker vm scopes data (Some changes) None

let incr_ptr t = t.current_ptr <- value_add t.current_ptr (Felt.small 3)

let register reg =
  (* squash_dict *)
  reg C.squash_dict (fun c vm ->
      let address = get_ptr vm c "dict_accesses" in
      let ptr_diff = get_z vm c "ptr_diff" in
      check (Z.equal (Z.erem ptr_diff (z 3)) Z.zero) "Accesses array size must be divisible by DictAccess.SIZE";
      let n = Z.to_int (get_z vm c "n_accesses") in
      let idx = Felt_tbl.create 64 in
      let order = ref [] in
      for i = 0 to n - 1 do
        let key = canon (mem_at vm address (3 * i)) in
        (match Felt_tbl.find_opt idx key with
        | Some l -> Felt_tbl.replace idx key (i :: l)
        | None ->
            order := key :: !order;
            Felt_tbl.replace idx key [ i ])
      done;
      Felt_tbl.filter_map_inplace (fun _ l -> Some (List.rev l)) idx;
      let keys = List.sort (fun a b -> compare_values b a) !order in
      (match keys with
      | k :: _ -> set_val vm c "big_keys" (of_bool (Felt.is_felt k && Z.geq (Felt.to_z k) rc_bound))
      | [] -> fail "squash_dict: no keys");
      (* Python pops the smallest key from the end. Keep the next key at the
         head so each subsequent pop shares the tail of the OCaml list. *)
      let first, rest = match List.rev keys with k :: rest -> (k, rest) | [] -> assert false in
      set c.scopes "access_indices" (Access_indices idx);
      set c.scopes "keys" (Values rest);
      set c.scopes "key" (Value first);
      set_val vm c "first_key" first);
  let pop_value name scopes =
    let r = cell scopes name in
    match !r with
    | Values (x :: xs) -> r := Values xs; x
    | Values [] -> fail "pop from empty list"
    | _ -> fail "%s is not a list of values" name
  in
  let pop_index name scopes =
    let r = cell scopes name in
    match !r with
    | Ints (x :: xs) -> r := Ints xs; x
    | Ints [] -> fail "pop from empty list"
    | _ -> fail "%s is not a list of indices" name
  in
  let access_list scopes =
    match (var scopes "access_indices", var scopes "key") with
    | Access_indices h, Value k -> (match Felt_tbl.find_opt h k with Some l -> l | None -> fail "key not in access_indices")
    | _ -> fail "squash_dict scope corrupted"
  in
  reg C.squash_dict_inner_first_iteration (fun c vm ->
      (* The collection loop already restores increasing access order. *)
      set c.scopes "current_access_indices" (Ints (access_list c.scopes));
      let cur = pop_index "current_access_indices" c.scopes in
      set c.scopes "current_access_index" (Int (z cur));
      let rc = get_ptr vm c "range_check_ptr" in
      write_checked vm (Felt.rseg rc) (Felt.roff rc) (Felt.small cur));
  let nonempty scopes name = match var scopes name with Ints l -> l <> [] | Values l -> l <> [] | _ -> fail "not a list" in
  reg C.squash_dict_inner_skip_loop (fun c vm -> set_val vm c "should_skip_loop" (of_bool (not (nonempty c.scopes "current_access_indices"))));
  reg C.squash_dict_inner_check_access_index (fun c vm ->
      let nw = pop_index "current_access_indices" c.scopes in
      let cur = Z.to_int (var_z c.scopes "current_access_index") in
      set_member vm c "loop_temps" [ "index_delta_minus1" ] (Felt.of_int (nw - cur - 1));
      set c.scopes "current_access_index" (Int (z nw)));
  reg C.squash_dict_inner_continue_loop (fun c vm -> set_member vm c "loop_temps" [ "should_continue" ] (of_bool (nonempty c.scopes "current_access_indices")));
  reg C.squash_dict_inner_len_assert (fun c _ -> check (not (nonempty c.scopes "current_access_indices")) "assert len(current_access_indices) == 0");
  reg C.squash_dict_inner_used_accesses_assert (fun c vm ->
      check (Z.equal (get_z vm c "n_used_accesses") (z (List.length (access_list c.scopes)))) "n_used_accesses mismatch");
  reg C.squash_dict_inner_assert_len_keys (fun c _ -> check (not (nonempty c.scopes "keys")) "assert len(keys) == 0");
  reg C.squash_dict_inner_next_key (fun c vm ->
      if not (nonempty c.scopes "keys") then fail "No keys left but remaining_accesses > 0.";
      let k = pop_value "keys" c.scopes in
      set c.scopes "key" (Value k);
      set_val vm c "next_key" k);
  (* dict_new *)
  reg C.dict_new (fun c vm ->
      let ptr = match var c.scopes "initial_dict" with
        | Initial_dict h -> new_dict vm c.scopes (Some h) None
        | Dict_snapshot frozen -> from_snapshot vm c.scopes frozen
        | _ -> fail "initial_dict has wrong type"
      in
      write_ap vm ptr;
      del c.scopes "initial_dict");
  (* dict_read *)
  reg C.dict_read (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "dict_ptr") in
      incr_ptr t;
      set_val vm c "value" (dict_lookup t (canon (get_val vm c "key"))));
  (* dict_write *)
  reg C.dict_write (fun c vm ->
      let dp = get_ptr vm c "dict_ptr" in
      let t = get_tracker c.scopes dp in
      incr_ptr t;
      let key = canon (get_val vm c "key") in
      let prev = dict_lookup t key in
      write_checked vm (Felt.rseg dp) (Felt.roff dp + 1) prev;
      dict_set t key (get_val vm c "new_value"));
  (* dict_update *)
  reg C.dict_update (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "dict_ptr") in
      let key = canon (get_val vm c "key") in
      let cur = dict_lookup t key in
      let prev = get_val vm c "prev_value" in
      if not (Felt.equal cur prev) then
        fail "Wrong previous value in dict. Got %s, expected %s." (value_to_string prev) (value_to_string cur);
      dict_set t key (get_val vm c "new_value");
      incr_ptr t);
  (* dict_squash: copy dict *)
  reg C.dict_squash_copy_dict (fun c vm ->
      let m = match var c.scopes "__dict_manager" with Dict_manager m -> m | _ -> fail "no dict manager" in
      let t = get_tracker c.scopes (get_ptr vm c "dict_accesses_end") in
      enter c.scopes [ ("__dict_manager", Dict_manager m); ("initial_dict", Dict_snapshot (snapshot t)) ]);
  reg C.dict_squash_update_ptr (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "squashed_dict_start") in
      t.current_ptr <- get_ptr vm c "squashed_dict_end");
  reg C.default_dict_new (fun c vm -> write_ap vm (new_dict vm c.scopes None (Some (get_val vm c "default_value"))))
