(* Builtin hint implementations, matched by exact code string as in
   cairo-vm's BuiltinHintProcessor.  Each mirrors the Python reference in
   cairo-lang 0.13.5.  Unknown hints fail when executed. *)

open Vm
open Hintrt
module H = Hint_codes

let table : (string, ctx -> vm -> unit) Hashtbl.t = Hashtbl.create 128
let reg code f = Hashtbl.replace table code f

let z = Z.of_int
let two_pow n = Z.shift_left Z.one n
let mask n = Z.pred (two_pow n)
let pz = Felt.p
let check b msg = if not b then fail "%s" msg

let secp_p = Z.of_string "115792089237316195423570985008687907853269984665640564039457584007908834671663"
let secp_n = Z.of_string "115792089237316195423570985008687907852837564279074904382605163141518161494337"

let div_mod n m p =
  let inverse = try Z.invert m p with Division_by_zero -> fail "div_mod: not invertible" in
  Z.erem (Z.mul n inverse) p

let pack vm ctx name path =
  let limb k = as_int (get_member_z vm ctx name (path @ [ k ])) in
  Z.add (limb "d0") (Z.add (Z.shift_left (limb "d1") 86) (Z.shift_left (limb "d2") 172))

let split3 num =
  check (Z.sign num >= 0 && Z.numbits num <= 258) "split: value too large";
  [Z.extract num 0 86; Z.extract num 86 86; Z.extract num 172 86]

let read_uint256 vm c name =
  let low = get_member_z vm c name [ "low" ] in
  let high = get_member_z vm c name [ "high" ] in
  Z.add (Z.shift_left high 128) low

let write_uint256 vm c name value =
  set_member vm c name [ "low" ] (zf (Z.extract value 0 128));
  set_member vm c name [ "high" ] (zf (Z.shift_right value 128))

let isqrt n = Z.sqrt n

(* ---- blake2s ---- *)
let iv =
  [| 0x6A09E667; 0xBB67AE85; 0x3C6EF372; 0xA54FF53A; 0x510E527F; 0x9B05688C; 0x1F83D9AB; 0x5BE0CD19 |]

let sigma =
  [|
    [| 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15 |];
    [| 14; 10; 4; 8; 9; 15; 13; 6; 1; 12; 0; 2; 11; 7; 5; 3 |];
    [| 11; 8; 12; 0; 5; 2; 15; 13; 10; 14; 3; 6; 7; 1; 9; 4 |];
    [| 7; 9; 3; 1; 13; 12; 11; 14; 2; 6; 5; 10; 4; 0; 15; 8 |];
    [| 9; 0; 5; 7; 2; 4; 10; 15; 14; 1; 11; 12; 6; 8; 3; 13 |];
    [| 2; 12; 6; 10; 0; 11; 8; 3; 4; 13; 7; 5; 15; 14; 1; 9 |];
    [| 12; 5; 1; 15; 14; 13; 4; 10; 0; 7; 6; 3; 9; 2; 8; 11 |];
    [| 13; 11; 7; 14; 12; 1; 3; 9; 5; 0; 15; 4; 8; 6; 2; 10 |];
    [| 6; 15; 14; 9; 11; 3; 0; 8; 12; 2; 13; 7; 1; 4; 10; 5 |];
    [| 10; 2; 8; 4; 7; 6; 1; 5; 15; 11; 9; 14; 3; 12; 13; 0 |];
  |]

let m32 = 0xFFFFFFFF
let rotr x n = ((x lsr n) lor (x lsl (32 - n))) land m32

let blake2s_compress (h : int array) (msg : int array) t0 t1 f0 f1 =
  let s = Array.make 16 0 in
  Array.blit h 0 s 0 8;
  Array.blit iv 0 s 8 4;
  s.(12) <- (iv.(4) lxor t0) land m32;
  s.(13) <- (iv.(5) lxor t1) land m32;
  s.(14) <- (iv.(6) lxor f0) land m32;
  s.(15) <- (iv.(7) lxor f1) land m32;
  let mix a b c d m0 m1 =
    s.(a) <- (s.(a) + s.(b) + m0) land m32;
    s.(d) <- rotr (s.(d) lxor s.(a)) 16;
    s.(c) <- (s.(c) + s.(d)) land m32;
    s.(b) <- rotr (s.(b) lxor s.(c)) 12;
    s.(a) <- (s.(a) + s.(b) + m1) land m32;
    s.(d) <- rotr (s.(d) lxor s.(a)) 8;
    s.(c) <- (s.(c) + s.(d)) land m32;
    s.(b) <- rotr (s.(b) lxor s.(c)) 7
  in
  for r = 0 to 9 do
    let sg = sigma.(r) in
    let m i = msg.(sg.(i)) in
    mix 0 4 8 12 (m 0) (m 1);
    mix 1 5 9 13 (m 2) (m 3);
    mix 2 6 10 14 (m 4) (m 5);
    mix 3 7 11 15 (m 6) (m 7);
    mix 0 5 10 15 (m 8) (m 9);
    mix 1 6 11 12 (m 10) (m 11);
    mix 2 7 8 13 (m 12) (m 13);
    mix 3 4 9 14 (m 14) (m 15)
  done;
  Array.init 8 (fun i -> h.(i) lxor s.(i) lxor s.(8 + i))

let to_u32 v =
  let n = Felt.to_nat v in
  if n < 0 || n > m32 then fail "blake2s: value is not a 32-bit word";
  n

(* ---- keccak ---- *)
let keccak_lanes (vals : Z.t array) =
  let st = Bytes.make 200 '\000' in
  Array.iteri (fun i v -> Bytes.set_int64_le st (8 * i) (Z.to_int64_unsigned v)) vals;
  Felt.keccak_f_bytes st;
  Array.init 25 (fun i -> Z.extract (Z.of_int64 (Bytes.get_int64_le st (8 * i))) 0 64)

let keccak256 (b : Bytes.t) =
  let out = Bytes.create 32 in
  Felt.keccak256_raw b out;
  out

let z_of_be (b : Bytes.t) off n =
  let r = ref Z.zero in
  for i = 0 to n - 1 do
    r := Z.add (Z.shift_left !r 8) (z (Char.code (Bytes.get b (off + i))))
  done;
  !r

(* Pack Cairo words into the big-endian byte stream consumed by keccak256.
   H40 validates the final partial word as well. H41 historically serializes
   the low 128 bits of each full word. *)
let keccak_input vm data ~first length ~check_width =
  let bytes = Bytes.create length and scratch = Bytes.create 32 in
  let rec fill offset i =
    if offset < length then begin
      let word = mem_at vm data i in
      if not (Felt.is_felt word) then fail "unsafe_keccak: expected an integer";
      let count = min 16 (length - offset) in
      if check_width && Felt.bits word > 8 * count then fail "unsafe_keccak: word out of range";
      Felt.c_put_code !Felt.pool word scratch 0;
      if count = 16 then begin
        Bytes.set_int64_be bytes offset (Bytes.get_int64_le scratch 8);
        Bytes.set_int64_be bytes (offset + 8) (Bytes.get_int64_le scratch 0)
      end else
        for j = 0 to count - 1 do
          Bytes.set bytes (offset + j) (Bytes.get scratch (count - 1 - j))
        done;
      fill (offset + count) (i + 1)
    end
  in
  fill 0 first;
  bytes

external absorb_keccak : bytes -> int -> bytes -> int = "cvm_keccak_absorb"
external snapshot_keccak : bytes -> int -> bytes -> unit = "cvm_keccak_snapshot"

type keccak_prefix = {
  start : int; checked : bool; state : bytes;
  mutable words : int; mutable used : int;
}

(* Bound the retained sponge states independently of the number of segments
   a program creates. Switching the VM drops all checkpoints. *)
type keccak_cursors = {
  mutable owner : vm option;
  slots : keccak_prefix option array;
  mutable next : int;
}

let keccak_cursors () = { owner = None; slots = Array.make 4 None; next = 0 }

let fresh_prefix cache i start checked =
  let p = { start; checked; state = Bytes.make 200 '\000'; words = 0; used = 0 } in
  cache.slots.(i) <- Some p;
  p

let rec find_prefix cache start checked n i =
  if i = Array.length cache.slots then begin
    let slot = cache.next in
    cache.next <- (slot + 1) mod Array.length cache.slots;
    fresh_prefix cache slot start checked
  end else match cache.slots.(i) with
    | Some p when p.start = start -> if p.words <= n && (p.checked || not checked) then p else fresh_prefix cache i start checked
    | _ -> find_prefix cache start checked n (i + 1)

let absorb_prefix ~checked cache vm start n =
  if n < 0 || n > Sys.max_string_length / 16 then fail "Invalid Keccak input length";
  (match cache.owner with
   | Some previous when previous == vm -> ()
   | _ ->
       Array.fill cache.slots 0 (Array.length cache.slots) None;
       cache.owner <- Some vm;
       cache.next <- 0);
  let prefix = find_prefix cache start checked n 0 in
  while prefix.words < n do
    let count = min 4096 (n - prefix.words) in
    let bytes = keccak_input vm start ~first:prefix.words (16 * count) ~check_width:checked in
    prefix.used <- absorb_keccak prefix.state prefix.used bytes;
    prefix.words <- prefix.words + count
  done;
  prefix

let digest_state state used =
  let digest = Bytes.create 32 in
  snapshot_keccak state used digest;
  digest

let finalize_keccak cache vm start n =
  let prefix = absorb_prefix ~checked:false cache vm start n in
  digest_state prefix.state prefix.used

let hash_byte_prefix cache vm data length =
  if length < 0 then fail "Invalid Keccak input length";
  let words = length / 16 and tail = length mod 16 in
  let prefix = absorb_prefix ~checked:true cache vm data words in
  if tail = 0 then digest_state prefix.state prefix.used
  else begin
    (* A partial word uses its shortest requested big-endian width. Never
       commit those bytes to a checkpoint for complete 16-byte words. *)
    let bytes = keccak_input vm data ~first:words tail ~check_width:true in
    let state = Bytes.copy prefix.state in
    let used = absorb_keccak state prefix.used bytes in
    digest_state state used
  end

let felt_z vm ctx n = get_z vm ctx n

let () =
  (* memory[ap] = segments.add() *)
  reg H.h0 (fun _ vm -> write_ap vm (Felt.reloc (add_segment vm) 0));
  (* assert_nn *)
  reg H.h1 (fun c ->
      let read = bound_felt c "a" in fun vm ->
      let a = read vm in
      if not (Felt.is_small a && a > 0) && Felt.bits a > 128 then
        fail "a = %s is out of range." (Z.to_string (Felt.to_z a)));
  (* assert_le_felt *)
  reg H.h2 (fun c vm ->
      let a = felt_z vm c "a" and b = felt_z vm c "b" in
      if Z.gt a b then fail "a = %s is not less than or equal to b = %s." (Z.to_string a) (Z.to_string b);
      let l = [ (a, 0); (Z.sub b a, 1); (Z.sub (Z.pred pz) b, 2) ] in
      let l = List.sort compare l in
      let l0, _ = List.nth l 0 and l1, _ = List.nth l 1 and _, excluded = List.nth l 2 in
      check (Z.leq l0 (Z.div pz (z 3)) && Z.leq l1 (Z.div pz (z 2))) "assert_le_felt: arc check failed";
      set c.scopes "excluded" (Int (z excluded));
      let rc = get_ptr vm c "range_check_ptr" in
      let p3 = const_z c "PRIME_OVER_3_HIGH" and p2 = const_z c "PRIME_OVER_2_HIGH" in
      let q0, r0 = Z.ediv_rem l0 p3 and q1, r1 = Z.ediv_rem l1 p2 in
      let w k v = write_checked vm (Felt.rseg rc) (Felt.roff rc + k) (zf v) in
      w 1 q0;
      w 0 r0;
      w 3 q1;
      w 2 r1);
  reg H.h3 (fun c vm -> write_ap vm (of_bool (not (Z.equal (var_z c.scopes "excluded") Z.zero))));
  reg H.h4 (fun c vm -> write_ap vm (of_bool (not (Z.equal (var_z c.scopes "excluded") Z.one))));
  reg H.h5 (fun c _ -> check (Z.equal (var_z c.scopes "excluded") (z 2)) "assert excluded == 2");
  reg H.h6 (fun c _ -> exit_scope c.scopes);
  (* unsigned_div_rem *)
  reg H.h7 (fun c vm ->
      let div = felt_z vm c "div" and value = felt_z vm c "value" in
      if Z.leq div Z.zero || Z.gt div (Z.div pz rc_bound) then fail "div=%s is out of the valid range." (Z.format "%x" div);
      let q, r = Z.ediv_rem value div in
      set_val vm c "q" (zf q);
      set_val vm c "r" (zf r));
  reg H.h8 (fun c vm -> enter c.scopes [ ("n", Int (felt_z vm c "len")) ]);
  reg H.h9 (fun c vm ->
      let n = Z.pred (var_z c.scopes "n") in
      set c.scopes "n" (Int n);
      set_val vm c "continue_copying" (of_bool (Z.gt n Z.zero)));
  (* assert_lt_felt *)
  reg H.h10 (fun c vm ->
      let a = felt_z vm c "a" and b = felt_z vm c "b" in
      if Z.geq a b then fail "a = %s is not less than b = %s." (Z.to_string a) (Z.to_string b));
  reg H.h11 (fun c ->
      let read = bound_felt c "a" in fun vm ->
      let a = read vm in
      write_ap vm (of_bool (if Felt.is_small a then a < 0 else Felt.bits a > 128)));
  reg H.h12 (fun c vm ->
      let a = felt_z vm c "a" in
      write_ap vm (if Z.lt (Z.erem (Z.sub (Z.neg a) Z.one) pz) rc_bound then Felt.zero else Felt.one));
  reg H.h13 (fun c vm -> enter c.scopes [ ("n", Int (felt_z vm c "n")) ]);
  reg H.h14 (fun c vm ->
      let n = Z.pred (var_z c.scopes "n") in
      set c.scopes "n" (Int n);
      set_val vm c "continue_loop" (of_bool (Z.gt n Z.zero)));
  (* uint256_add *)
  reg H.h15 (fun c vm ->
      let shift = Option.value (const_opt c "SHIFT") ~default:rc_bound in
      let g n m = get_member_z vm c n [ m ] in
      let sum_low = Z.add (g "a" "low") (g "b" "low") in
      let carry_low = if Z.geq sum_low shift then Z.one else Z.zero in
      set_val vm c "carry_low" (zf carry_low);
      let sum_high = Z.add (Z.add (g "a" "high") (g "b" "high")) carry_low in
      set_val vm c "carry_high" (zf (if Z.geq sum_high shift then Z.one else Z.zero)));
  (* split_felt *)
  reg H.h16 (fun c vm ->
      let v = felt_z vm c "value" in
      set_member vm c "low" [] (zf (Z.logand v (mask 128))) |> ignore;
      ())
  ;
  ()

(* split_felt writes ids.low / ids.high as plain felt variables *)
let () =
  reg H.h16 (fun c vm ->
      let low, high = Felt.split_at_limb ~two_limbs:true (get_felt vm c "value") in
      set_val vm c "low" low;
      set_val vm c "high" high);
  reg H.h17 (fun c vm ->
      let e = get_member_z vm c "prev_locs" [ "exp" ] in
      set_member vm c "locs" [ "bit" ] (zf (Z.logand e Z.one)));
  reg H.h18 (fun c vm -> if Z.equal (felt_z vm c "value") Z.zero then fail "assert_not_zero failed: 0 = 0.");
  (* blake2s compute *)
  reg H.h19 (fun c vm ->
      let out = get_ptr vm c "output" in
      let at k = mem_at vm (Felt.reloc (Felt.rseg out) 0) (Felt.roff out + k) in
      let h = Array.init 8 (fun i -> to_u32 (at (i - 26))) in
      let msg = Array.init 16 (fun i -> to_u32 (at (i - 18))) in
      let t = to_u32 (at (-2)) and f = to_u32 (at (-1)) in
      let r = blake2s_compress h msg t 0 f 0 in
      write_arg vm out (Array.to_list (Array.map Felt.small r)));
  (* blake2s finalize padding *)
  reg H.h20 (fun c vm ->
      let n = Z.to_int (const_z c "N_PACKED_INSTANCES") in
      check (0 <= n && n < 20) "N_PACKED_INSTANCES out of range";
      let sz = Z.to_int (const_z c "INPUT_BLOCK_FELTS") in
      check (0 <= sz && sz < 100) "INPUT_BLOCK_FELTS out of range";
      let message = Array.make sz 0 in
      let miv = Array.copy iv in
      miv.(0) <- iv.(0) lxor 0x01010020;
      let output = blake2s_compress miv (Array.append message (Array.make (max 0 (16 - sz)) 0)) 0 0 0xffffffff 0 in
      let one = Array.to_list miv @ Array.to_list message @ [ 0; 0xffffffff ] @ Array.to_list output in
      let pad = List.concat (List.init (n - 1) (fun _ -> one)) in
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (List.map Felt.small pad));
  let blake_words low high rev =
    let w v i = Z.to_int (Z.logand (Z.shift_right v (32 * i)) (z m32)) in
    if rev then (List.init 4 (fun i -> w high (3 - i)), List.init 4 (fun i -> w low (3 - i)))
    else (List.init 4 (fun i -> w low i), List.init 4 (fun i -> w high i))
  in
  reg H.h21 (fun c vm ->
      let a, b = blake_words (felt_z vm c "low") (felt_z vm c "high") false in
      let d = get_ptr vm c "data" in
      write_arg vm d (List.map Felt.small a);
      write_arg vm (value_add d (Felt.small 4)) (List.map Felt.small b));
  reg H.h22 (fun c vm ->
      let a, b = blake_words (felt_z vm c "low") (felt_z vm c "high") true in
      let d = get_ptr vm c "data" in
      write_arg vm d (List.map Felt.small a);
      write_arg vm (value_add d (Felt.small 4)) (List.map Felt.small b));
  reg H.h23 (fun c _ -> enter c.scopes [])

(* ---- dicts ---- *)
let dict_manager scopes =
  match var_opt scopes "__dict_manager" with
  | Some (Dict_manager m) -> m
  | _ ->
      let m = Hashtbl.create 8 in
      set scopes "__dict_manager" (Dict_manager m);
      m

let get_tracker scopes ptr =
  let m = match var_opt scopes "__dict_manager" with Some (Dict_manager m) -> m | _ -> fail "No dict manager" in
  if not (Felt.is_reloc ptr) then fail "dict_ptr is not a pointer";
  match Hashtbl.find_opt m (Felt.rseg ptr) with
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
      (match Hashtbl.find_opt t.data key with
       | Some v -> v
       | None -> match t.default with Some d -> d | None -> fail "Dict Error: no value found for key %s" (value_to_string key))

let dict_set t key value =
  match t.changes with
  | None -> Hashtbl.replace t.data key value
  | Some m -> t.changes <- Some (Dict_changes.add key value m)

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
  Hashtbl.replace m s { data; changes; default; current_ptr = ptr };
  ptr

let new_dict vm scopes initial default =
  let data = Hashtbl.create 16 in
  (match initial with Some h -> Hashtbl.iter (fun k v -> Hashtbl.replace data k v) h | None -> ());
  add_tracker vm scopes data None default

let from_snapshot vm scopes (data, changes) = add_tracker vm scopes data (Some changes) None

let incr_ptr t = t.current_ptr <- value_add t.current_ptr (Felt.small 3)

let () =
  (* squash_dict *)
  reg H.h24 (fun c vm ->
      let address = get_ptr vm c "dict_accesses" in
      let ptr_diff = felt_z vm c "ptr_diff" in
      check (Z.equal (Z.erem ptr_diff (z 3)) Z.zero) "Accesses array size must be divisible by DictAccess.SIZE";
      let n = Z.to_int (felt_z vm c "n_accesses") in
      let idx = Hashtbl.create 64 in
      let order = ref [] in
      for i = 0 to n - 1 do
        let key = canon (mem_at vm address (3 * i)) in
        (match Hashtbl.find_opt idx key with
        | Some l -> Hashtbl.replace idx key (i :: l)
        | None ->
            order := key :: !order;
            Hashtbl.replace idx key [ i ])
      done;
      Hashtbl.filter_map_inplace (fun _ l -> Some (List.rev l)) idx;
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
  let pop_next name scopes =
    match var scopes name with
    | Values (x :: xs) -> set scopes name (Values xs); x
    | Ints (x :: xs) -> set scopes name (Ints xs); x
    | Ints [] | Values [] -> fail "pop from empty list"
    | _ -> fail "%s is not a list" name
  in
  let access_list scopes =
    match (var scopes "access_indices", var scopes "key") with
    | Access_indices h, Value k -> (match Hashtbl.find_opt h k with Some l -> l | None -> fail "key not in access_indices")
    | _ -> fail "squash_dict scope corrupted"
  in
  reg H.h25 (fun c vm ->
      (* The collection loop already restores increasing access order. *)
      set c.scopes "current_access_indices" (Ints (access_list c.scopes));
      let cur = pop_next "current_access_indices" c.scopes in
      set c.scopes "current_access_index" (Int (z cur));
      let rc = get_ptr vm c "range_check_ptr" in
      write_checked vm (Felt.rseg rc) (Felt.roff rc) (Felt.small cur));
  let nonempty scopes name = match var scopes name with Ints l | Values l -> l <> [] | _ -> fail "not a list" in
  reg H.h26 (fun c vm -> set_val vm c "should_skip_loop" (of_bool (not (nonempty c.scopes "current_access_indices"))));
  reg H.h27 (fun c vm ->
      let nw = pop_next "current_access_indices" c.scopes in
      let cur = Z.to_int (var_z c.scopes "current_access_index") in
      set_member vm c "loop_temps" [ "index_delta_minus1" ] (Felt.of_int (nw - cur - 1));
      set c.scopes "current_access_index" (Int (z nw)));
  reg H.h28 (fun c vm -> set_member vm c "loop_temps" [ "should_continue" ] (of_bool (nonempty c.scopes "current_access_indices")));
  reg H.h29 (fun c _ -> check (not (nonempty c.scopes "current_access_indices")) "assert len(current_access_indices) == 0");
  reg H.h30 (fun c vm ->
      check (Z.equal (felt_z vm c "n_used_accesses") (z (List.length (access_list c.scopes)))) "n_used_accesses mismatch");
  reg H.h31 (fun c _ -> check (not (nonempty c.scopes "keys")) "assert len(keys) == 0");
  reg H.h32 (fun c vm ->
      if not (nonempty c.scopes "keys") then fail "No keys left but remaining_accesses > 0.";
      let k = pop_next "keys" c.scopes in
      set c.scopes "key" (Value k);
      set_val vm c "next_key" k);
  (* dict_new *)
  reg H.h33 (fun c vm ->
      let ptr = match var c.scopes "initial_dict" with
        | Initial_dict h -> new_dict vm c.scopes (Some h) None
        | Dict_snapshot frozen -> from_snapshot vm c.scopes frozen
        | _ -> fail "initial_dict has wrong type"
      in
      write_ap vm ptr;
      del c.scopes "initial_dict");
  (* dict_read *)
  reg H.h34 (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "dict_ptr") in
      incr_ptr t;
      set_val vm c "value" (dict_lookup t (canon (get_val vm c "key"))));
  (* dict_write *)
  reg H.h35 (fun c vm ->
      let dp = get_ptr vm c "dict_ptr" in
      let t = get_tracker c.scopes dp in
      incr_ptr t;
      let key = canon (get_val vm c "key") in
      let prev = dict_lookup t key in
      write_checked vm (Felt.rseg dp) (Felt.roff dp + 1) prev;
      dict_set t key (get_val vm c "new_value"));
  (* dict_update *)
  reg H.h36 (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "dict_ptr") in
      let key = canon (get_val vm c "key") in
      let cur = dict_lookup t key in
      let prev = get_val vm c "prev_value" in
      if not (Felt.equal cur prev) then
        fail "Wrong previous value in dict. Got %s, expected %s." (value_to_string prev) (value_to_string cur);
      dict_set t key (get_val vm c "new_value");
      incr_ptr t);
  (* dict_squash: copy dict *)
  reg H.h37 (fun c vm ->
      let m = match var c.scopes "__dict_manager" with Dict_manager m -> m | _ -> fail "no dict manager" in
      let t = get_tracker c.scopes (get_ptr vm c "dict_accesses_end") in
      enter c.scopes [ ("__dict_manager", Dict_manager m); ("initial_dict", Dict_snapshot (snapshot t)) ]);
  reg H.h38 (fun c vm ->
      let t = get_tracker c.scopes (get_ptr vm c "squashed_dict_start") in
      t.current_ptr <- get_ptr vm c "squashed_dict_end");
  reg H.h39 (fun c vm -> write_ap vm (new_dict vm c.scopes None (Some (get_val vm c "default_value"))))

(* A completed block records the maximum seen since row zero. These maxima
   are ordered even when the input is unsorted. A relocatable terminates any
   scan, so it never needs to be inserted into the index. *)
type lower_index = { mutable maxima : int array; mutable blocks : int }
type lower_cursor = {
  owner : vm; base : int; stride : int;
  mutable last_key : int; mutable last_index : int;
  mutable index : lower_index option;
}

let lower_block_size = 128

let search_lower cursor vm arr width length key =
  let row i = mem_at vm arr (width * i) in
  let reaches v = Felt.is_reloc v || Felt.compare v key >= 0 in
  let rec scan i =
    if i = length || reaches (row i) then i else scan (i + 1)
  in
  let indexed t =
    let rec first_block lo hi =
      if lo = hi then lo else
        let mid = lo + (hi - lo) / 2 in
        if Felt.compare t.maxima.(mid) key >= 0 then first_block lo mid
        else first_block (mid + 1) hi
    in
    let block = first_block 0 t.blocks in
    let start = min length (block * lower_block_size) in
    if block < t.blocks then scan start
    else begin
      let rec extend i maximum =
        if i = length then i else
          let v = row i in
          if reaches v then i else begin
            let maximum = if Felt.compare v maximum > 0 then v else maximum in
            let next = i + 1 in
            if next mod lower_block_size = 0 then begin
              if t.blocks = Array.length t.maxima then
                t.maxima <- Array.append t.maxima (Array.make t.blocks Felt.zero);
              t.maxima.(t.blocks) <- maximum;
              t.blocks <- t.blocks + 1
            end;
            extend next maximum
          end
      in
      extend start (if block = 0 then Felt.zero else t.maxima.(block - 1))
    end
  in
  match !cursor with
  | Some c when c.owner == vm && c.base = arr && c.stride = width ->
      let answer =
        match c.index with
        | Some t -> indexed t
        | None when Felt.compare key c.last_key >= 0 -> scan (min length c.last_index)
        | None when c.last_index < lower_block_size -> scan 0
        | None ->
            let t = {maxima = Array.make 8 Felt.zero; blocks = 0} in
            c.index <- Some t;
            indexed t
      in
      c.last_key <- key; c.last_index <- answer; answer
  | _ ->
      let answer = scan 0 in
      cursor := Some { owner = vm; base = arr; stride = width; last_key = key;
                       last_index = answer; index = None };
      answer

let () =
  (* unsafe_keccak *)
  reg H.h40 (fun c ->
      let prefix = keccak_cursors () in
      fun vm ->
      let data = get_ptr vm c "data" in
      let length = Z.to_int (felt_z vm c "length") in
      let h = hash_byte_prefix prefix vm data length in
      set_val vm c "high" (zf (z_of_be h 0 16));
      set_val vm c "low" (zf (z_of_be h 16 16)));
  reg H.h41 (fun c ->
      let prefix = keccak_cursors () in
      fun vm ->
      let st = get_member vm c "keccak_state" [ "start_ptr" ] and en = get_member vm c "keccak_state" [ "end_ptr" ] in
      let n = Felt.to_nat (value_sub en st) in
      let h = finalize_keccak prefix vm st n in
      set_val vm c "high" (zf (z_of_be h 0 16));
      set_val vm c "low" (zf (z_of_be h 16 16)));
  reg H.h42 (fun c vm ->
      let low = felt_z vm c "low" and high = felt_z vm c "high" in
      let inp = get_ptr vm c "inputs" in
      let sp v = [ zf (Z.logand v (mask 64)); zf (Z.shift_right v 64) ] in
      write_arg vm inp (sp low);
      write_arg vm (value_add inp (Felt.small 2)) (sp high));
  reg H.h43 (fun c vm -> write_ap vm (of_bool (Z.lt (felt_z vm c "n_bytes") (const_z c "BYTES_IN_WORD"))));
  reg H.h44 (fun c vm ->
      let n = Z.to_int (const_z c "KECCAK_STATE_SIZE_FELTS") in
      check (0 <= n && n < 100) "KECCAK_STATE_SIZE_FELTS out of range";
      let kp = get_ptr vm c "keccak_ptr" in
      let vals = read_range vm (value_sub kp (Felt.small n)) n |> List.map Felt.to_z |> Array.of_list in
      check (n = 25) "keccak_func expects 25 lanes";
      write_arg vm kp (Array.to_list (Array.map zf (keccak_lanes vals))));
  reg H.h45 (fun c vm -> write_ap vm (of_bool (Z.geq (felt_z vm c "n_bytes") (const_z c "KECCAK_FULL_RATE_IN_BYTES"))));
  reg H.h46 (fun c vm ->
      let n = Z.to_int (const_z c "KECCAK_STATE_SIZE_FELTS") and bs = Z.to_int (const_z c "BLOCK_SIZE") in
      check (0 <= n && n < 100 && 0 <= bs && bs < 10) "keccak finalize constants out of range";
      let inp = Array.make 25 Z.zero in
      let one = Array.to_list (Array.map zf inp) @ Array.to_list (Array.map zf (keccak_lanes inp)) in
      write_arg vm (get_ptr vm c "keccak_ptr_end") (List.concat (List.init bs (fun _ -> one))));
  reg H.h47 (fun c vm -> write_ap vm (if Z.leq (felt_z vm c "a") (felt_z vm c "b") then Felt.zero else Felt.one));
  (* assert_not_equal *)
  reg H.h48 (fun c vm ->
      let a = get_val vm c "a" and b = get_val vm c "b" in
      let ok =
        (Felt.is_felt a && Felt.is_felt b) || (Felt.is_reloc a && Felt.is_reloc b && Felt.rseg a = Felt.rseg b)
      in
      if not ok then fail "assert_not_equal failed: non-comparable values";
      if Felt.equal a b then fail "assert_not_equal failed: %s = %s." (value_to_string a) (value_to_string b));
  (* assert_250_bit *)
  reg H.h49 (fun c vm ->
      let v = felt_z vm c "value" in
      if Z.geq v (const_z c "UPPER_BOUND") then fail "%s is outside of the range [0, 2**250)." (Z.to_string v);
      let hi, lo = Z.ediv_rem v (const_z c "SHIFT") in
      set_val vm c "high" (zf hi);
      set_val vm c "low" (zf lo));
  reg H.h50 (fun c vm ->
      let a = get_felt vm c "value" in
      let positive = if Felt.is_small a then Felt.small_val a > 0 else begin
        let v = as_int (Felt.to_z a) in
        if Z.geq (Z.abs v) rc_bound then fail "value=%s is out of the valid range." (Z.to_string v);
        Z.sign v > 0
      end in set_val vm c "is_positive" (of_bool positive));
  reg H.h51 (fun c vm -> if not (Z.equal (felt_z vm c "value") Z.zero) then fail "split_int(): value is out of range.");
  reg H.h52 (fun c vm ->
      let res = Z.erem (felt_z vm c "value") (felt_z vm c "base") in
      if Z.geq res (felt_z vm c "bound") then fail "split_int(): Limb %s is out of range." (Z.to_string res);
      let o = get_ptr vm c "output" in
      write_checked vm (Felt.rseg o) (Felt.roff o) (zf res));
  (* signed_div_rem *)
  reg H.h53 (fun c vm ->
      let div = felt_z vm c "div" in
      if Z.leq div Z.zero || Z.gt div (Z.div pz rc_bound) then fail "div=%s is out of the valid range." (Z.format "%x" div);
      let bound = felt_z vm c "bound" in
      if Z.gt bound (Z.div rc_bound (z 2)) then fail "bound is out of the valid range.";
      let v = as_int (felt_z vm c "value") in
      let q = Z.fdiv v div in
      let r = Z.sub v (Z.mul q div) in
      if Z.lt q (Z.neg bound) || Z.geq q bound then fail "signed_div_rem: quotient out of range";
      set_val vm c "r" (zf r);
      set_val vm c "biased_q" (zf (Z.add q bound)));
  (* find_element *)
  reg H.h54 (fun c ->
      let cache = ref None in
      fun vm ->
        let arr = get_ptr vm c "array_ptr" in
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        if es <= 0 then fail "Invalid value for elm_size.";
        let key = get_val vm c "key" in
        let n = Felt.to_nat (get_felt vm c "n_elms") in
        if n < 0 then fail "Invalid value for n_elms.";
        let index = Find_element.lookup cache vm arr es n key in
        set_val vm c "index" (Felt.small index));
  reg H.h55 (fun c ->
      let cursor = ref None in
      fun vm ->
        let arr = get_ptr vm c "array_ptr" in
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        if es <= 0 then fail "Invalid value for elm_size.";
        let n = Felt.to_nat (get_felt vm c "n_elms") in
        if n < 0 then fail "Invalid value for n_elms.";
        let key = get_felt vm c "key" in
        let index = search_lower cursor vm arr es n key in
        set_val vm c "index" (Felt.small index));
  reg H.h56 (fun c _ -> enter c.scopes [ ("__usort_max_size", Nothing) ]);
  reg H.h57 (fun c vm ->
      let inp = get_ptr vm c "input" in
      let n = Felt.to_nat (get_felt vm c "input_len") in
      let pos = Hashtbl.create 64 in
      let keys = ref [] in
      for i = 0 to n - 1 do
        let v = canon (mem_at vm inp i) in
        match Hashtbl.find_opt pos v with
        | Some l -> Hashtbl.replace pos v (i :: l)
        | None ->
            keys := v :: !keys;
            Hashtbl.replace pos v [ i ]
      done;
      Hashtbl.filter_map_inplace (fun _ l -> Some (List.rev l)) pos;
      let out = List.sort compare_values !keys in
      set c.scopes "positions_dict" (Positions pos);
      set_val vm c "output_len" (Felt.small (List.length out));
      set_val vm c "output" (gen_arg vm out);
      set_val vm c "multiplicities" (gen_arg vm (List.map (fun k -> Felt.small (List.length (Hashtbl.find pos k))) out)));
  reg H.h58 (fun c vm ->
      set c.scopes "last_pos" (Int Z.zero);
      let pos = match var c.scopes "positions_dict" with Positions p -> p | _ -> fail "positions_dict missing" in
      let l = match Hashtbl.find_opt pos (canon (get_val vm c "value")) with Some l -> l | None -> [] in
      (* h57 stores positions in increasing order. Consume that immutable list
         from the head, preserving positions_dict for subsequent lookups. *)
      set c.scopes "positions" (Ints l));
  reg H.h59 (fun c _ -> match var c.scopes "positions" with Ints [] -> () | _ -> fail "assert len(positions) == 0");
  reg H.h60 (fun c vm ->
      let cur, rest =
        match var c.scopes "positions" with
        | Ints (cur :: rest) -> (cur, rest)
        | Ints [] -> fail "pop from empty list"
        | _ -> fail "positions"
      in
      set c.scopes "positions" (Ints rest);
      let last = Z.to_int (var_z c.scopes "last_pos") in
      set_val vm c "next_item_index" (Felt.small (cur - last));
      set c.scopes "last_pos" (Int (z (cur + 1))));
  let ptr_diff vm c =
    let d = value_sub (get_val vm c "elements_end") (get_val vm c "elements") in
    Felt.to_z d
  in
  reg H.h61 (fun c vm -> write_ap vm (of_bool (Z.geq (ptr_diff vm c) (z 10))));
  reg H.h62 (fun c vm -> write_ap vm (of_bool (Z.geq (ptr_diff vm c) (z 2))))

(* ---- set membership ---- *)

(* Cairo memory is write-once. A row whose first word has been read can
   be ruled out for any different first word, even if its suffix has holes.
   Cache the earliest row for each first word and check matching rows with
   the ordinary element comparison. Keep just one range per compiled hint. *)
let set_word_hash v = if Felt.is_big v then Z.hash (Felt.to_z v) else Hashtbl.hash v

module Set_words = Hashtbl.Make (struct
  type t = int
  let equal = Felt.equal
  let hash = set_word_hash
end)

module Set_rows = Hashtbl.Make (struct
  type t = int array
  let equal a b = Array.length a = Array.length b && Array.for_all2 Felt.equal a b
  let hash = Array.fold_left (fun h v -> (h * 65599) lxor set_word_hash v) 0
end)

type complete_rows = { rows : int Set_rows.t; mutable next : int }

type set_index = {
  owner : vm;
  base : int;
  width : int;
  first : int Set_words.t;
  mutable composite : complete_rows option;
  mutable scanned : int; (* cell offset of the next unindexed row *)
}

let find_set_element cache vm base total elm =
  let es = Array.length elm and e0 = elm.(0) in
  let seg = Felt.rseg base and start = Felt.roff base in
  let mem = vm.segs.(seg) in
  let capacity = slen mem in
  let cell off =
    let v = sget mem off in
    if v = 0 then fail "Unknown memory cell %d:%d" seg off;
    v
  in
  let index =
    if total / es < 32 then None
    else match !cache with
      | Some t when t.owner == vm && t.base = base && t.width = es -> !cache
      | _ ->
          let t = { owner = vm; base; width = es; first = Set_words.create 32; scanned = 0; composite = None } in
          cache := Some t;
          (* A single lookup pays only for the scan. Start indexing if this
             hint sees the same range again. *)
          None
  in
  let from = match index with
    | None -> 0
    | Some t -> Option.value (Set_words.find_opt t.first e0) ~default:t.scanned
  in
  let rec search collisions i =
    if i >= total then -1
    else begin
      let off = start + i in
      if off + es > capacity then fail "Unknown memory cell %d:%d" seg off;
      let v = cell off in
      (match index with
      | Some t when i = t.scanned ->
          if not (Set_words.mem t.first v) then Set_words.add t.first v i;
          t.scanned <- i + es
      | _ -> ());
      if Felt.equal v e0 then begin
        let j = ref 1 in
        while !j < es && Felt.equal (cell (off + !j)) elm.(!j) do incr j done;
        if !j = es then i / es else begin
          if collisions = 15 && es > 1 then
            (match index with
             | Some t when t.composite = None ->
                 t.composite <- Some {rows = Set_rows.create 32; next = 0}
             | _ -> ());
          search (collisions + 1) (i + es)
        end
      end else search collisions (i + es)
    end
  in
  match index with
  | Some {composite = Some t; _} ->
      (match Set_rows.find_opt t.rows elm with
       | Some i -> if i < total then i / es else -1
       | None ->
           let rec extend i =
             if i >= total then -1 else begin
               let off = start + i in
               (* A hole in an unexamined suffix is not necessarily an error.
                  Resume the ordinary short-circuit comparison at this row. *)
               let rec complete j = j = es || (sget mem (off+j) <> 0 && complete (j+1)) in
               if es > capacity - off || not (complete 0) then search 0 (max i from)
               else begin
                 let row = Array.init es (fun j -> sget mem (off+j)) in
                 if not (Set_rows.mem t.rows row) then Set_rows.add t.rows row i;
                 t.next <- i + es;
                 if Array.for_all2 Felt.equal row elm then i / es else extend t.next
               end
             end
           in
           extend t.next)
  | _ -> search 0 from

(* ---- secp ---- *)
let () =
  let setz c n v = set c.scopes n (Int v) in
  let getz c n = var_z c.scopes n in
  reg H.h63 (fun c vm ->
      write_arg vm (get_addr vm c "res") (List.map zf (split3 (getz c "value"))));
  reg H.h64 (fun c vm ->
      let d0 = get_member_z vm c "x" [ "d0" ] and d1 = get_member_z vm c "x" [ "d1" ] in
      set_val vm c "low" (zf (Z.logand (Z.add d0 (Z.mul d1 (const_z c "BASE"))) (mask 128))));
  reg H.h65 (fun c vm ->
      let q, r = Z.ediv_rem (pack vm c "val" []) secp_p in
      if not (Z.equal r Z.zero) then fail "verify_zero: Invalid input";
      set_val vm c "q" (zf q));
  reg H.h66 (fun c vm -> setz c "x" (Z.erem (pack vm c "x" []) secp_p));
  reg H.h67 (fun c vm -> write_ap vm (of_bool (Z.equal (getz c "x") Z.zero)));
  reg H.h68 (fun c _ ->
      let v = div_mod Z.one (getz c "x") secp_p in
      setz c "value" v;
      setz c "x_inv" v);
  reg H.h69 (fun c vm -> setz c "value" (Z.erem (pack vm c "x" []) secp_p));
  reg H.h70 (fun c vm ->
      let y = Z.erem (pack vm c "point" [ "y" ]) secp_p in
      setz c "y" y;
      setz c "value" (Z.erem (Z.neg y) secp_p));
  reg H.h71 (fun c vm ->
      let x = pack vm c "point" [ "x" ] and y = pack vm c "point" [ "y" ] in
      setz c "x" x;
      setz c "y" y;
      check (not (Z.equal (Z.erem y secp_p) Z.zero)) "ec_double_slope: y == 0";
      let s = div_mod (Z.mul (z 3) (Z.mul x x)) (Z.mul (z 2) y) secp_p in
      setz c "value" s;
      setz c "slope" s);
  reg H.h72 (fun c vm ->
      let x0 = pack vm c "point0" [ "x" ] and y0 = pack vm c "point0" [ "y" ] in
      let x1 = pack vm c "point1" [ "x" ] and y1 = pack vm c "point1" [ "y" ] in
      List.iter (fun (n, v) -> setz c n v) [ ("x0", x0); ("y0", y0); ("x1", x1); ("y1", y1) ];
      check (not (Z.equal (Z.erem (Z.sub x0 x1) secp_p) Z.zero)) "line_slope: same x";
      let s = div_mod (Z.sub y0 y1) (Z.sub x0 x1) secp_p in
      setz c "value" s;
      setz c "slope" s);
  reg H.h73 (fun c vm ->
      let slope = pack vm c "slope" [] and x = pack vm c "point" [ "x" ] and y = pack vm c "point" [ "y" ] in
      setz c "slope" slope;
      setz c "x" x;
      setz c "y" y;
      let nx = Z.erem (Z.sub (Z.mul slope slope) (Z.mul (z 2) x)) secp_p in
      setz c "value" nx;
      setz c "new_x" nx);
  reg H.h74 (fun c _ ->
      let ny = Z.erem (Z.sub (Z.mul (getz c "slope") (Z.sub (getz c "x") (getz c "new_x"))) (getz c "y")) secp_p in
      setz c "value" ny;
      setz c "new_y" ny);
  reg H.h75 (fun c vm ->
      let slope = pack vm c "slope" [] and x0 = pack vm c "point0" [ "x" ] and x1 = pack vm c "point1" [ "x" ] in
      let y0 = pack vm c "point0" [ "y" ] in
      List.iter (fun (n, v) -> setz c n v) [ ("slope", slope); ("x0", x0); ("x1", x1); ("y0", y0) ];
      let nx = Z.erem (Z.sub (Z.sub (Z.mul slope slope) x0) x1) secp_p in
      setz c "value" nx;
      setz c "new_x" nx);
  reg H.h76 (fun c _ ->
      let ny = Z.erem (Z.sub (Z.mul (getz c "slope") (Z.sub (getz c "x0") (getz c "new_x"))) (getz c "y0")) secp_p in
      setz c "value" ny;
      setz c "new_y" ny);
  reg H.h77 (fun c vm -> write_ap vm (zf (Z.erem (felt_z vm c "scalar") (z 2))));
  reg H.h78 (fun c vm ->
      let a = pack vm c "a" [] and b = pack vm c "b" [] in
      setz c "a" a;
      setz c "b" b;
      let r = div_mod a b secp_n in
      setz c "value" r;
      setz c "res" r);
  reg H.h79 (fun c _ ->
      let x = Z.sub (Z.mul (getz c "res") (getz c "b")) (getz c "a") in
      if not (Z.equal (Z.erem x secp_n) Z.zero) then fail "safe_div: not divisible";
      let k = Z.div x secp_n in
      setz c "value" k;
      setz c "k" k);
  reg H.h80 (fun c vm ->
      let xc = Z.erem (pack vm c "x_cube" []) secp_p in
      let ys = Z.erem (Z.add xc (const_z c "BETA")) secp_p in
      let y = Z.powm ys (Z.div (Z.succ secp_p) (z 4)) secp_p in
      let v = felt_z vm c "v" in
      setz c "value" (if Z.equal (Z.erem v (z 2)) (Z.erem y (z 2)) then y else Z.erem (Z.neg y) secp_p));
  reg H.h81 (fun c ->
      let cache = ref None in
      fun vm ->
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        check (es > 0) "assert ids.elm_size > 0";
        let sp = get_ptr vm c "set_ptr" and se = get_ptr vm c "set_end_ptr" in
        check (Felt.rseg sp = Felt.rseg se && Felt.roff sp <= Felt.roff se) "assert ids.set_ptr <= ids.set_end_ptr";
        let ep = get_ptr vm c "elm_ptr" in
        let elm = Array.of_list (read_range vm ep es) in
        let found = find_set_element cache vm sp (Felt.roff se - Felt.roff sp) elm in
        if found < 0 then set_val vm c "is_elm_in_set" Felt.zero
        else begin
          set_val vm c "index" (Felt.small found);
          set_val vm c "is_elm_in_set" Felt.one
        end);
  reg H.h82 (fun c ->
      let read = bound_felt c "a" and lo = bound_set c "low" and hi = bound_set c "high" in
      fun vm ->
        let low, high = Felt.split_at_limb ~two_limbs:false (read vm) in
        lo vm low;
        hi vm high);
  reg H.h83 (fun c vm ->
      let n = Z.add (Z.shift_left (get_member_z vm c "n" [ "high" ]) 128) (get_member_z vm c "n" [ "low" ]) in
      let root = isqrt n in
      check (Z.lt root (two_pow 128)) "uint256_sqrt: root out of range";
      set_member vm c "root" [ "low" ] (zf root);
      set_member vm c "root" [ "high" ] Felt.zero);
  reg H.h84 (fun c vm -> write_ap vm (of_bool (Z.lt (get_member_z vm c "a" [ "high" ]) (two_pow 127))));
  reg H.h85 (fun c vm ->
      let a = read_uint256 vm c "a" and d = read_uint256 vm c "div" in
      if Z.equal d Z.zero then fail "uint256_unsigned_div_rem: division by zero";
      let q, r = Z.ediv_rem a d in
      write_uint256 vm c "quotient" q;
      write_uint256 vm c "remainder" r);
  reg H.uint256_mul_div_mod (fun c vm ->
      let a = read_uint256 vm c "a" and b = read_uint256 vm c "b" in
      let d = read_uint256 vm c "div" in
      if Z.equal d Z.zero then fail "uint256_mul_div_mod: division by zero";
      let q, r = Z.ediv_rem (Z.mul a b) d in
      (* Rust's Uint512::split writes exactly four 128-bit quotient limbs. *)
      write_uint256 vm c "quotient_low" (Z.extract q 0 256);
      write_uint256 vm c "quotient_high" (Z.extract q 256 256);
      write_uint256 vm c "remainder" r)

let compile prog scopes (h : Program.hint) : vm -> unit =
  let ctx = make_ctx prog scopes h in
  match Hashtbl.find_opt table h.code with
  | Some f -> f ctx
  | None ->
      fun _ ->
        fail "Unknown hint: %s" (if String.length h.code > 80 then String.sub h.code 0 80 ^ "..." else h.code)
