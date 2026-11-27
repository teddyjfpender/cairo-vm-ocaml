(* Keccak hints: unsafe_keccak with incremental sponge checkpoints,
   cairo_keccak block permutations and padding, and keccak_utils splits
   (cairo-vm keccak_utils.rs, cairo_keccak/keccak_hints.rs). *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

let u64_bound = two_pow 64

let keccak_lanes (vals : Z.t array) =
  let st = Bytes.make 200 '\000' in
  Array.iteri (fun i v -> Bytes.set_int64_le st (8 * i) (Z.to_int64_unsigned v)) vals;
  Felt.keccak_f_bytes st;
  Array.init 25 (fun i -> Z.extract (Z.of_int64 (Bytes.get_int64_le st (8 * i))) 0 64)

let keccak256 (b : Bytes.t) =
  let out = Bytes.create 32 in
  Felt.keccak256_raw b out;
  out

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
      Felt.c_put_code Felt.pool (word :> int) scratch 0;
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
  start : Felt.t; checked : bool; state : bytes;
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

let register reg =
  reg C.unsafe_keccak (fun c ->
      let prefix = keccak_cursors () in
      fun vm ->
      let data = get_ptr vm c "data" in
      let length = Z.to_int (get_z vm c "length") in
      let h = hash_byte_prefix prefix vm data length in
      set_val vm c "high" (zf (z_of_be (Bytes.sub_string h 0 16)));
      set_val vm c "low" (zf (z_of_be (Bytes.sub_string h 16 16))));
  reg C.unsafe_keccak_finalize (fun c ->
      let prefix = keccak_cursors () in
      fun vm ->
      let st = get_member vm c "keccak_state" [ "start_ptr" ] and en = get_member vm c "keccak_state" [ "end_ptr" ] in
      let n = Felt.to_nat (value_sub en st) in
      let h = finalize_keccak prefix vm st n in
      set_val vm c "high" (zf (z_of_be (Bytes.sub_string h 0 16)));
      set_val vm c "low" (zf (z_of_be (Bytes.sub_string h 16 16))));
  reg C.keccak_write_args (fun c vm ->
      let low = get_z vm c "low" and high = get_z vm c "high" in
      let inp = get_ptr vm c "inputs" in
      let sp v = [ zf (Z.logand v (mask 64)); zf (Z.shift_right v 64) ] in
      write_arg vm inp (sp low);
      write_arg vm (value_add inp (Felt.small 2)) (sp high));
  reg C.compare_bytes_in_word_nondet (fun c vm -> write_ap vm (of_bool (Z.lt (get_z vm c "n_bytes") (const_z c "BYTES_IN_WORD"))));
  reg C.block_permutation (fun c vm ->
      let n = Z.to_int (const_z c "KECCAK_STATE_SIZE_FELTS") in
      check (0 <= n && n < 100) "KECCAK_STATE_SIZE_FELTS out of range";
      let kp = get_ptr vm c "keccak_ptr" in
      let vals = read_range vm (value_sub kp (Felt.small n)) n |> List.map Felt.to_z |> Array.of_list in
      check (n = 25) "keccak_func expects 25 lanes";
      write_arg vm kp (Array.to_list (Array.map zf (keccak_lanes vals))));
  reg C.compare_keccak_full_rate_in_bytes_nondet (fun c vm -> write_ap vm (of_bool (Z.geq (get_z vm c "n_bytes") (const_z c "KECCAK_FULL_RATE_IN_BYTES"))));
  reg C.cairo_keccak_finalize_v1 (fun c vm ->
      let n = Z.to_int (const_z c "KECCAK_STATE_SIZE_FELTS") and bs = Z.to_int (const_z c "BLOCK_SIZE") in
      check (0 <= n && n < 100 && 0 <= bs && bs < 10) "keccak finalize constants out of range";
      let inp = Array.make 25 Z.zero in
      let one = Array.to_list (Array.map zf inp) @ Array.to_list (Array.map zf (keccak_lanes inp)) in
      write_arg vm (get_ptr vm c "keccak_ptr_end") (List.concat (List.init bs (fun _ -> one))));
  let state_size c =
    let n = const_full c "starkware.cairo.common.cairo_keccak.keccak.KECCAK_STATE_SIZE_FELTS" in
    if Z.geq n (z 100) then fail "Invalid keccak state size felts: %s" (Z.to_string n);
    Z.to_int n
  in
  let lanes vm ptr n =
    let vals =
      Array.init n (fun i ->
          let v = get vm (Felt.rseg ptr) (Felt.roff ptr + i) in
          if not (Felt.is_felt v) then fail "Expected integer at keccak state range";
          let x = Felt.to_z v in
          if Z.geq x u64_bound then fail "Felt %s does not fit a u64" (Z.to_string x);
          x)
    in
    if n <> 25 then fail "Keccak state must have 25 lanes, got %d" n;
    keccak_lanes vals
  in
  reg C.block_permutation_whitelist_v1 (fun c vm ->
      let n = state_size c in
      let kp = get_ptr vm c "keccak_ptr" in
      let out = lanes vm (value_sub kp (Felt.small n)) n in
      write_arg vm kp (Array.to_list (Array.map Felt.of_z out)));
  reg C.block_permutation_whitelist_v2 (fun c vm ->
      let n = state_size c in
      let out = lanes vm (get_ptr vm c "keccak_ptr_start") n in
      write_arg vm (get_ptr vm c "output") (Array.to_list (Array.map Felt.of_z out)));
  reg C.cairo_keccak_input_is_full_word (fun c vm ->
      set_val vm c "full_word" (of_bool (Z.geq (get_z vm c "n_bytes") (z 8))));
  reg C.cairo_keccak_finalize_v2 (fun c vm ->
      let n = const_full c "starkware.cairo.common.cairo_keccak.keccak.KECCAK_STATE_SIZE_FELTS" in
      let bs = const_full c "starkware.cairo.common.cairo_keccak.packed_keccak.BLOCK_SIZE" in
      if Z.geq n (z 100) then fail "Invalid keccak state size felts: %s" (Z.to_string n);
      if Z.geq bs (z 1000) then fail "Invalid block size: %s" (Z.to_string bs);
      let n = Z.to_int n and bs = Z.to_int bs in
      if n <> 25 then fail "Keccak state must have 25 lanes, got %d" n;
      if bs = 0 then fail "Invalid block size: 0";
      let inp = Array.make 25 Z.zero in
      let one = List.init n (fun _ -> Felt.zero) @ Array.to_list (Array.map Felt.of_z (keccak_lanes inp)) in
      write_arg vm (get_ptr vm c "keccak_ptr_end") (List.concat (List.init bs (fun _ -> one))));

  (* ---------------- keccak_utils splits ---------------- *)
  let split_output k c vm =
    let v = get_z vm c (Printf.sprintf "output%d" k) in
    set_val vm c (Printf.sprintf "output%d_high" k) (Felt.of_z (Z.shift_right v 128));
    set_val vm c (Printf.sprintf "output%d_low" k) (Felt.of_z (Z.logand v (mask 128)))
  in
  reg C.split_output_0 (split_output 0);
  reg C.split_output_1 (split_output 1);
  let split_input key e c vm =
    let v = z_at vm (get_ptr vm c "inputs") key in
    set_val vm c (Printf.sprintf "high%d" key) (Felt.of_z (Z.shift_right v (8 * e)));
    set_val vm c (Printf.sprintf "low%d" key) (Felt.of_z (Z.logand v (mask (8 * e))))
  in
  reg C.split_input_3 (split_input 3 1);
  reg C.split_input_6 (split_input 6 2);
  reg C.split_input_9 (split_input 9 3);
  reg C.split_input_12 (split_input 12 4);
  reg C.split_input_15 (split_input 15 5);
  reg C.split_n_bytes (fun c vm ->
      let n = get_z vm c "n_bytes" in
      if Z.geq n u64_bound then fail "Felt %s does not fit a u64" (Z.to_string n);
      let w = const_full c "starkware.cairo.common.builtin_keccak.keccak.BYTES_IN_WORD" in
      if Z.geq w u64_bound then fail "Missing constant BYTES_IN_WORD";
      if Z.equal w Z.zero then fail "Attempted to divide by zero";
      let q, r = Z.ediv_rem n w in
      set_val vm c "n_words_to_copy" (Felt.of_z q);
      set_val vm c "n_bytes_left" (Felt.of_z r));
  reg C.split_output_mid_low_high (fun c vm ->
      let v = get_z vm c "output1" in
      let tmp = Z.shift_right v 56 and low = Z.logand v (mask 56) in
      set_val vm c "output1_high" (Felt.of_z (Z.shift_right tmp 128));
      set_val vm c "output1_mid" (Felt.of_z (Z.logand tmp (mask 128)));
      set_val vm c "output1_low" (Felt.of_z low))
