(* Builtin auto-deduction of output cells (cairo-vm deduce_memory_cell). *)

open Felt
open Errors
open Builtin
open Vm


let cache_get b off = if off < Array.length b.cache then b.cache.(off) else 0

let cache_set b off v =
  if off >= Array.length b.cache then begin
    let n = ref (max 64 (Array.length b.cache)) in
    while !n <= off do
      n := 2 * !n
    done;
    let na = Array.make !n 0 in
    Array.blit b.cache 0 na 0 (Array.length b.cache);
    b.cache <- na
  end;
  b.cache.(off) <- v

(* inputs of instance starting at [inst]; None if a cell is missing *)
let input_felts vm seg inst n =
  let r = Array.make n 0 in
  let ok = ref true in
  for i = 0 to n - 1 do
    let v = read vm seg (inst + i) in
    if v = 0 then ok := false
    else if not (is_felt v) then fail "Builtin %d: expected integer at %d:%d" seg seg (inst + i)
    else r.(i) <- v
  done;
  if !ok then Some r else None

(* Inputs and raw outputs occupy reserved, uncommitted slots at the end of
   the pool. Compact the canonical outputs forward, starting at the input
   base: the write cursor can never overtake an unread output. Only big
   results advance pool_n. The caller reserved space for the whole block. *)
let cache_outputs b off first_output count =
  for i = 0 to count - 1 do
    let result = c_code_of_slot !pool (first_output + i) !pool_n in
    commit result;
    cache_set b (off + i) result
  done

let bitwise_output vm seg off idx =
  let base = off - idx in
  let x = read vm seg base and y = read vm seg (base + 1) in
  if (x <> 0 && not (is_felt x)) || (y <> 0 && not (is_felt y)) then
    fail "Builtin %d: expected integer at %d:%d" seg seg
      (if x <> 0 && not (is_felt x) then base else base + 1);
  if x = 0 || y = 0 then 0
  else if both_small x y && x >= 0 && y >= 0 then
    (match idx with 2 -> x land y | 3 -> (x lxor y) lor 1 | _ -> x lor y)
  else begin
    reserve 1;
    let r = c_bitwise !pool (idx - 2) x y !pool_n in
    if r = 0 then
      fail "Bitwise builtin: integer at %d:%d is bigger than 2^251" seg
        (if Felt.bits x > 251 then base else base + 1);
    commit r;
    r
  end

let deduce_builtin vm (b : builtin) seg off =
  let cpi = cells_per_instance b.kind in
  let idx = off mod cpi in
  let nin = n_input_cells b.kind in
  if idx < nin then 0
  else if b.kind = Bitwise then bitwise_output vm seg off idx
  else begin
    let c = cache_get b off in
    if c <> 0 then c
    else begin
      let inst = off - idx in
      match input_felts vm seg inst nin with
      | None -> 0
      | Some inp -> (
          match b.kind with
          | Pedersen ->
              (* Equal adjacent inputs have equal hashes. Reuse only an
                 output already computed by this builtin, never a memory
                 value supplied by the program. *)
              let prev = if inst >= cpi then cache_get b (off - cpi) else 0 in
              let r =
                if prev <> 0 && Felt.equal inp.(0) (read vm seg (inst - cpi))
                   && Felt.equal inp.(1) (read vm seg (inst - cpi + 1)) then prev
                else begin
                  reserve 1;
                  let result = c_pedersen !pool inp.(0) inp.(1) !pool_n in
                  commit result;
                  result
                end
              in
              cache_set b off r;
              r
          | Poseidon ->
              reserve 6;
              let s = !pool_n in
              for i = 0 to 2 do
                c_load_slot !pool inp.(i) (s + i)
              done;
              c_poseidon !pool s (s + 3);
              cache_outputs b (inst + 3) (s + 3) 3;
              cache_get b off
          | Keccak ->
              Array.iteri
                (fun k v -> if Felt.bits v > 200 then fail "Keccak builtin: input %d:%d exceeds 2^200" seg (inst + k))
                inp;
              reserve 16;
              let s = !pool_n in
              for i = 0 to 7 do
                c_load_slot !pool inp.(i) (s + i)
              done;
              c_keccak !pool s (s + 8);
              cache_outputs b (inst + 8) (s + 8) 8;
              cache_get b off
          | Ec_op ->
              reserve 7;
              let s = !pool_n in
              for i = 0 to 4 do
                c_load_slot !pool inp.(i) (s + i)
              done;
              let rc = c_ec_op !pool s (s + 5) in
              if rc = 2 then fail "EcOp builtin: point not on curve";
              if rc = 1 then fail "EcOp builtin: EcOpSameXCoordinate";
              if rc <> 0 then fail "EcOp builtin: invalid point";
              cache_outputs b (inst + 5) (s + 5) 2;
              cache_get b off
          | _ -> 0)
    end
  end

let[@inline never] deduce_cell vm seg off =
  if seg >= 0 && seg < vm.nsegs && is_deducing vm.seg_flag.(seg) then
    match vm.seg_builtin.(seg) with Some b -> deduce_builtin vm b seg off | None -> 0
  else 0
