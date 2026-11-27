(* Instruction decoding (cairo-vm decoder.rs, including the v4.0.0
   classify_instruction restriction to Stwo-supported shapes). *)

open Errors

let ext_shift = 61
let ext_mask = 3 lsl ext_shift
let two_128 = Z.shift_left Z.one 128
let low_63 = Z.pred (Z.shift_left Z.one 63)

exception Generic_instruction

(* cairo-vm v4.0.0 classify_instruction: only the instruction shapes that have a
   dedicated Stwo opcode component are executable.  Field codes as packed below:
   op1 0 op0/1 imm/2 fp/3 ap; res 0 op1/1 add/2 mul/3 unconstrained;
   pc 0 regular/1 jump/2 jump_rel/3 jnz; ap 0 regular/1 add/2 add1/3 add2;
   opcode 0 nop/1 call/2 ret/3 assert_eq; dst/op0 registers 0 ap/1 fp. *)
let stwo_supported ~ext o0 o1 o2 dst op0 op1 res pc ap opc =
  let ap01 = ap = 0 || ap = 2 and reg = op1 = 2 || op1 = 3 and fp_fp = dst = 1 && op0 = 1 in
  (op1 <> 1 || o2 = 1)
  &&
  match ext with
  | 0 -> (
      match opc with
      | 2 -> o0 = -2 && o1 = -1 && o2 = -1 && fp_fp && op1 = 2 && res = 0 && pc = 1 && ap = 0
      | 1 -> o0 = 0 && o1 = 1 && dst = 0 && op0 = 0 && res = 0 && ap = 3 && ((op1 = 1 && pc = 2) || (reg && pc = 1))
      | 3 ->
          pc = 0 && ap01
          && ((res = 0 && (op1 = 0 || (o1 = -1 && op0 = 1 && op1 <> 0))) || ((res = 1 || res = 2) && op1 <> 0))
      | _ ->
          (* ap += x; jmp rel x; jmp abs [reg + o2]; jmp abs [[reg + o1] + o2]; jnz *)
          (o0 = -1 && dst = 1 && res = 0
          && ((o1 = -1 && op0 = 1 && op1 <> 0 && ((pc = 0 && ap = 1) || (pc = 2 && ap01) || (pc = 1 && reg && ap01)))
             || (pc = 1 && op1 = 0 && ap01)))
          || (o1 = -1 && op0 = 1 && op1 = 1 && res = 3 && pc = 3 && ap01))
  | 1 | 2 -> opc = 0 && reg && res = 0 && pc = 0 && ap01
  | _ -> opc = 3 && op1 <> 0 && (res = 1 || res = 2) && pc = 0 && ap01

let decode_word (w : Z.t) =
  if Z.geq w two_128 then fail "Invalid instruction encoding (does not fit in 128 bits)";
  let ext =
    let e = Z.shift_right w 63 in
    if Z.geq e (Z.of_int 4) then fail "Invalid opcode extension %s" (Z.to_string e);
    Z.to_int e
  in
  let w = Z.logand w low_63 in
  let w = Z.to_int64_unsigned w in
  let f k n = Int64.to_int (Int64.logand (Int64.shift_right_logical w k) (Int64.of_int ((1 lsl n) - 1))) in
  let off0 = f 0 16 and off1 = f 16 16 and off2 = f 32 16 in
  let flags = f 48 15 in
  let dst = flags land 1 and op0 = (flags lsr 1) land 1 and op1 = (flags lsr 2) land 7 in
  let res = (flags lsr 5) land 3 and pcu = (flags lsr 7) land 7 and apu = (flags lsr 10) land 3 in
  let opc = (flags lsr 12) land 7 in
  let onehot n = n = 0 || n = 1 || n = 2 || n = 4 in
  if not (onehot op1) then fail "Invalid op1_reg value: %d" op1;
  if not (onehot pcu) then fail "Invalid pc_update value: %d" pcu;
  if res = 3 || (pcu = 4 && res <> 0) then fail "Invalid res value: %d" res;
  if not (onehot opc) then fail "Invalid opcode value: %d" opc;
  if apu = 3 || (opc = 1 && apu <> 0) then fail "Invalid ap_update value: %d" apu;
  if opc = 1 && not (off0 = 0x8000 && off1 = 0x8001 && dst = 0 && op0 = 0) then fail "Invalid opcode value: %d" opc;
  if opc = 2 && not (off0 = 0x7ffe && off2 = 0x7fff && dst = 1 && op1 = 2 && res = 0 && pcu = 1) then
    fail "Invalid opcode value: %d" opc;
  let op1c = match op1 with 0 -> 0 | 1 -> 1 | 2 -> 2 | _ -> 3 in
  let resc = if pcu = 4 then 3 else res in
  let pcc = match pcu with 0 -> 0 | 1 -> 1 | 2 -> 2 | _ -> 3 in
  let apc = if apu = 0 then (if opc = 1 then 3 else 0) else if apu = 1 then 1 else 2 in
  let opcc = match opc with 0 -> 0 | 1 -> 1 | 2 -> 2 | _ -> 3 in
  (* cairo-vm decoder: flag restrictions of the Stwo extensions *)
  if (ext = 1 || ext = 2)
     && not (opc = 0 && (op1 = 2 || op1 = 4) && res = 0 && pcu = 0 && (apu = 0 || apu = 2)) then
    fail "Invalid Blake2s flags: %d" flags;
  if ext = 3
     && not ((res = 1 || res = 2) && op1 <> 0 && pcu = 0 && opc = 4 && (apu = 0 || apu = 2)) then
    fail "Invalid QM31 add/mul flags: %d" flags;
  if not (stwo_supported ~ext (off0 - 0x8000) (off1 - 0x8000) (off2 - 0x8000) dst op0 op1c resc pcc apc opcc) then
    raise Generic_instruction;
  (ext lsl ext_shift) lor off0 lor (off1 lsl 16) lor (off2 lsl 32) lor (dst lsl 48) lor (op0 lsl 49) lor (op1c lsl 50) lor (resc lsl 52)
  lor (pcc lsl 54) lor (apc lsl 56) lor (opcc lsl 58) lor (1 lsl 60)
