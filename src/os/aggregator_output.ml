(* Decode the full OS outputs carried by the simple bootloader. The sequencer
   allocates state and storage dictionaries once and appends to them across
   tasks, including when a contract reappears after intervening blocks. *)
open Errors
open Hintrt

external word_count : string -> int = "cvm_hex_array_count" [@@noalloc]
external decode_hex : Felt.pool -> string -> Felt.t array -> int -> int = "cvm_hex_array_parse" [@@noalloc]

(* A failed speculative decode leaves the pool cursor unchanged. The general
   JSON reader handles escaped strings, decimal words and empty arrays. *)
let decode_input raw =
  let fallback () =
    Array.of_list (List.map Os_hints.felt (Yojson.Safe.Util.to_list (Json_reader.from_string raw))) in
  let count = word_count raw in
  if count = 0 || count > 4 * 1024 * 1024 then fallback ()
  else
    let words = Array.make count Felt.zero in
    let next = decode_hex Felt.pool raw words !(Felt.pool_n) in
    if next < 0 then fallback () else begin
      Felt.pool_n := next;
      words
    end

type reader = { words : Felt.t array; mutable index : int }

let take r =
  if r.index = Array.length r.words then fail "Truncated aggregator OS output";
  let value = r.words.(r.index) in
  r.index <- r.index + 1;
  value

let count r =
  let word = take r in
  let remaining = Array.length r.words - r.index in
  if Felt.compare word (Felt.small remaining) > 0 then fail "Invalid aggregator output length";
  Felt.to_nat word

let bounded bits value =
  if Felt.bits value > bits then fail "Aggregator integer exceeds %d bits" bits;
  value

let segment vm = Felt.reloc (Vm.add_segment vm) 0
let temporary vm = Felt.reloc (Vm.add_temp_segment vm) 0
let advance ptr n = Vm.reloc_add_felt ptr (Felt.small n)

let append vm ptr words =
  write_arg vm !ptr words;
  ptr := advance !ptr (List.length words)

let messages vm r ~to_l1 =
  let size = count r in
  let stop = r.index + size in
  let base = temporary vm in
  let dst = ref base in
  while r.index < stop do
    let from_addr = bounded (if to_l1 then 251 else 160) (take r) in
    let to_addr = bounded (if to_l1 then 160 else 251) (take r) in
    append vm dst [from_addr; to_addr];
    if not to_l1 then begin
      let nonce = take r in
      let selector = take r in
      append vm dst [nonce; selector]
    end;
    let length = count r in
    if length > stop - r.index then fail "Invalid aggregator message payload";
    append vm dst [Felt.small length];
    for _ = 1 to length do append vm dst [take r] done
  done;
  if r.index <> stop then fail "Invalid aggregator message segment";
  base, !dst

let proof_facts vm r =
  let base = segment vm in
  let dst = ref base in
  let n = count r in
  for _ = 1 to n do
    let size = count r in
    let facts = gen_arg vm (List.init size (fun _ -> take r)) in
    append vm dst [Felt.small size; facts]
  done;
  base, !dst

type contract = { entries : Felt.t ref; storage : Felt.t ref }

let write_task vm r destination contracts state classes =
  let initial = take r in
  let final = take r in
  let prev = take r in
  if not (Felt.equal prev (Felt.small (-1))) then ignore (bounded 64 prev);
  let next = bounded 64 (take r) in
  let prev_hash = take r in
  let next_hash = take r in
  let os_hash = take r in
  let config = take r in
  let kzg = take r in
  let full = take r in
  if not (Felt.equal kzg Felt.zero && Felt.equal full Felt.one) then
    fail "Aggregator requires an uncommitted full OS state diff";
  let l1_first,l1_last = messages vm r ~to_l1:true in
  let l2_first,l2_last = messages vm r ~to_l1:false in
  let facts_first,facts_last = proof_facts vm r in
  let state_start = !state and classes_start = !classes in
  let n_contracts = count r in
  for _ = 1 to n_contracts do
    let addr = bounded 251 (take r) in
    let prev_nonce = take r in
    let new_nonce = take r in
    let prev_class = take r in
    let new_class = take r in
    let entry = match Felt_tbl.find_opt contracts addr with
      | Some c -> c
      | None ->
          let entries = ref (segment vm) in
          let storage = ref (segment vm) in
          append vm entries [prev_class; !storage; prev_nonce];
          let c = {entries;storage} in Felt_tbl.add contracts addr c; c in
    let changes = count r in
    for _ = 1 to changes do
      let key = bounded 251 (take r) in
      let before = take r in
      let after = take r in
      append vm entry.storage [key; before; after]
    done;
    let current = !(entry.entries) in
    append vm entry.entries [new_class; !(entry.storage); new_nonce];
    append vm state [addr; advance current (-3); current]
  done;
  let n_classes = count r in
  for _ = 1 to n_classes do
    let hash = take r in
    let before = take r in
    let after = take r in
    append vm classes [hash; before; after]
  done;
  let roots = gen_arg vm [initial; final] in
  let header = gen_arg vm [roots; prev; next; prev_hash; next_hash; os_hash; config; kzg; full] in
  let updates = gen_arg vm [state_start; Felt.small n_contracts; classes_start; Felt.small n_classes] in
  let first = gen_arg vm [l1_first; l2_first; facts_first] in
  let last = gen_arg vm [l1_last; l2_last; facts_last] in
  append vm destination [header; updates; first; last]

let load vm c words =
  let r = {words;index=0} in
  let tasks = count r in
  if tasks = 0 then fail "Aggregator needs at least one task";
  let destination = ref (get_ptr vm c "os_outputs") in
  let state = ref (segment vm) in
  let classes = ref (segment vm) in
  let contracts = Felt_tbl.create 16 and program_hash = ref None in
  for _ = 1 to tasks do
    ignore (take r); (* Cairo independently computes the serialized task size. *)
    let hash = take r in
    (match !program_hash with
     | Some previous when not (Felt.equal previous hash) -> fail "Aggregator program hashes differ"
     | _ -> program_hash := Some hash);
    write_task vm r destination contracts state classes
  done;
  set_val vm c "os_program_hash" (Option.get !program_hash);
  set_val vm c "n_tasks" (Felt.small tasks)
