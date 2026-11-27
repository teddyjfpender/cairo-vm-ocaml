(* Builtin auto-deduction of output cells (cairo-vm deduce_memory_cell). *)

open Felt
open Errors
open Builtin
open Vm


let cache_get b off = if off < Array.length b.cache then b.cache.(off) else Felt.empty

let cache_set b off v =
  if off >= Array.length b.cache then begin
    let n = ref (max 64 (Array.length b.cache)) in
    while !n <= off do
      n := 2 * !n
    done;
    let na = Array.make !n Felt.empty in
    Array.blit b.cache 0 na 0 (Array.length b.cache);
    b.cache <- na
  end;
  b.cache.(off) <- v

(* inputs of instance starting at [inst]; None if a cell is missing *)
let input_felts vm seg inst n =
  let r = Array.make n Felt.empty in
  let ok = ref true in
  for i = 0 to n - 1 do
    let v = read vm seg (inst + i) in
    if v = Felt.empty then ok := false
    else if not (is_felt v) then fail "Builtin %d: expected integer at %d:%d" seg seg (inst + i)
    else r.(i) <- v
  done;
  if !ok then Some r else None

let cache_outputs b off (out : Felt.t array) = Array.iteri (fun i r -> cache_set b (off + i) r) out

let bitwise_output vm seg off idx =
  let base = off - idx in
  let x = read vm seg base and y = read vm seg (base + 1) in
  let bad v = v <> Felt.empty && not (is_felt v) in
  if bad x || bad y then fail "Builtin %d: expected integer at %d:%d" seg seg (if bad x then base else base + 1);
  if x = Felt.empty || y = Felt.empty then Felt.empty
  else begin
    let r = Felt.bitwise (idx - 2) x y in
    if r = Felt.empty then
      fail "Bitwise builtin: integer at %d:%d is bigger than 2^251" seg (if Felt.bits x > 251 then base else base + 1);
    r
  end

let deduce_builtin vm (b : builtin) seg off =
  let cpi = cells_per_instance b.kind in
  let idx = off mod cpi in
  let nin = n_input_cells b.kind in
  if idx < nin then Felt.empty
  else if b.kind = Bitwise then bitwise_output vm seg off idx
  else begin
    let c = cache_get b off in
    if c <> Felt.empty then c
    else begin
      let inst = off - idx in
      match input_felts vm seg inst nin with
      | None -> Felt.empty
      | Some inp -> (
          match b.kind with
          | Pedersen ->
              (* Equal adjacent inputs have equal hashes. Reuse only an
                 output already computed by this builtin, never a memory
                 value supplied by the program. *)
              let prev = if inst >= cpi then cache_get b (off - cpi) else Felt.empty in
              let r =
                if prev <> Felt.empty && Felt.equal inp.(0) (read vm seg (inst - cpi))
                   && Felt.equal inp.(1) (read vm seg (inst - cpi + 1)) then prev
                else Felt.pedersen inp.(0) inp.(1)
              in
              cache_set b off r;
              r
          | Poseidon ->
              cache_outputs b (inst + 3) (Felt.poseidon inp);
              cache_get b off
          | Keccak ->
              Array.iteri
                (fun k v -> if Felt.bits v > 200 then fail "Keccak builtin: input %d:%d exceeds 2^200" seg (inst + k))
                inp;
              cache_outputs b (inst + 8) (Felt.keccak inp);
              cache_get b off
          | Ec_op -> (
              match Felt.ec_op inp with
              | Ok out ->
                  cache_outputs b (inst + 5) out;
                  cache_get b off
              | Error 2 -> fail "EcOp builtin: point not on curve"
              | Error 1 -> fail "EcOp builtin: EcOpSameXCoordinate"
              | Error _ -> fail "EcOp builtin: invalid point")
          | _ -> Felt.empty)
    end
  end

let[@inline never] deduce_cell vm seg off =
  if seg >= 0 && seg < vm.nsegs && is_deducing vm.seg_flag.(seg) then
    match vm.seg_builtin.(seg) with Some b -> deduce_builtin vm b seg off | None -> Felt.empty
  else Felt.empty
