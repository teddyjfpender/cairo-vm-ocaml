(* Cairo CPU, memory and builtins.

   Semantics follow a formal executable model of
   lambdaclass/cairo-vm v3.2.0: operand addresses are computed from the
   original memory, missing op0/op1 are first deduced by the owning builtin,
   then by the Stone inverse rules; dst is deduced only from res (ASSERT_EQ) or
   fp (CALL).  Deduced cells are written in op0, op1, dst order. *)

open Felt

exception Vm_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Vm_error s)) fmt

(* ---------------- builtins ---------------- *)

type bkind =
  | Output
  | Pedersen
  | Range_check
  | Ecdsa
  | Bitwise
  | Ec_op
  | Keccak
  | Poseidon
  | Range_check96
  | Add_mod
  | Mul_mod

let bname = function
  | Output -> "output"
  | Pedersen -> "pedersen"
  | Range_check -> "range_check"
  | Ecdsa -> "ecdsa"
  | Bitwise -> "bitwise"
  | Ec_op -> "ec_op"
  | Keccak -> "keccak"
  | Poseidon -> "poseidon"
  | Range_check96 -> "range_check96"
  | Add_mod -> "add_mod"
  | Mul_mod -> "mul_mod"

let all_builtins =
  [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96; Add_mod; Mul_mod ]

let bkind_of_name s =
  let s = if String.length s > 8 && String.sub s (String.length s - 8) 8 = "_builtin" then String.sub s 0 (String.length s - 8) else s in
  List.find_opt (fun k -> bname k = s) all_builtins

let cells_per_instance = function
  | Output | Range_check | Range_check96 -> 1
  | Pedersen -> 3
  | Ecdsa -> 2
  | Bitwise -> 5
  | Ec_op -> 7
  | Keccak -> 16
  | Poseidon -> 6
  | Add_mod | Mul_mod -> 7

let n_input_cells = function
  | Output | Range_check | Range_check96 -> 1
  | Pedersen -> 2
  | Ecdsa -> 2
  | Bitwise -> 2
  | Ec_op -> 5
  | Keccak -> 8
  | Poseidon -> 3
  | Add_mod | Mul_mod -> 7

type builtin = {
  kind : bkind;
  base : int; (* segment index *)
  included : bool;
  mutable stop_ptr : int;
  mutable cache : int array; (* deduced output codes by offset, 0 = none *)
}


(* Memory segments and the trace live outside the OCaml heap: every cell is an
   immediate, so there is nothing for the GC to scan or barrier. *)
module BA = Bigarray.Array1
type seg = (int, Bigarray.int_elt, Bigarray.c_layout) BA.t
external seg_make : int -> seg = "cvm_zalloc"
let empty_seg : seg = seg_make 0
let[@inline] slen (a : seg) = BA.dim a
let[@inline] sget (a : seg) i = BA.unsafe_get a i
let[@inline] sset (a : seg) i v = BA.unsafe_set a i v
let seg_grow (a : seg) n = let na = seg_make n in BA.blit a (BA.sub na 0 (BA.dim a)); na

(* segment flags *)
let k_plain = 0
let k_rc = 1
let k_rc96 = 2
let k_deduce = 3 (* pedersen, bitwise, ec_op, keccak, poseidon *)
let k_bitwise = 5
let k_pedersen = 6
let k_poseidon = 7
let k_keccak = 8
let k_ec_op = 9
let is_deducing k = k = k_deduce || (k >= k_bitwise && k <= k_ec_op)
let k_ecdsa = 4

type vm = {
  mutable segs : seg array;
  mutable nsegs : int;
  mutable seg_flag : int array;
  mutable hi : int array; (* used size: max written offset + 1 *)
  mutable seg_builtin : builtin option array;
  mutable pc_seg : int;
  mutable pc : int;
  mutable ap : int; (* offset in segment 1 *)
  mutable fp : int;
  mutable steps : int;
  (* decoded instruction cache for segment 0: 0 = not decoded *)
  mutable icache : int array;
  (* trace *)
  trace_on : bool;
  mutable trace : seg; (* tagged packed entries or full pc, ap, fp triples *)
  mutable tlen : int;
  mutable builtins : builtin list;
}

let create ~trace =
  {
    segs = Array.make 16 empty_seg;
    nsegs = 0;
    seg_flag = Array.make 16 0;
    hi = Array.make 16 0;
    seg_builtin = Array.make 16 None;
    pc_seg = 0;
    pc = 0;
    ap = 0;
    fp = 0;
    steps = 0;
    icache = [||];
    trace_on = trace;
    trace = (if trace then seg_make (1 lsl 26) else empty_seg);
    tlen = 0;
    builtins = [];
  }

let add_segment vm =
  let n = vm.nsegs in
  if n >= Array.length vm.segs then begin
    let grow a d = Array.append a (Array.make (Array.length a) d) in
    vm.segs <- grow vm.segs empty_seg;
    vm.seg_flag <- grow vm.seg_flag 0;
    vm.hi <- grow vm.hi 0;
    vm.seg_builtin <- grow vm.seg_builtin None
  end;
  vm.segs.(n) <- seg_make (if n = 1 then 1 lsl 27 else 16);
  vm.nsegs <- n + 1;
  n

(* ---------------- memory ---------------- *)

let[@inline] seg_ok vm seg = seg >= 0 && seg < vm.nsegs

let[@inline] read vm seg off =
  let a = Array.unsafe_get vm.segs seg in
  if off < slen a then sget a off else 0

let get vm seg off =
  if not (seg_ok vm seg) then fail "Unknown memory segment %d" seg;
  if off < 0 then 0 else read vm seg off

let[@inline never] grow_seg vm seg off =
  let a = vm.segs.(seg) in
  let n = ref (max 16 (slen a)) in
  while !n <= off do
    n := 2 * !n
  done;
  vm.segs.(seg) <- seg_grow a !n

let value_to_string v =
  if v = 0 then "<empty>"
  else if is_reloc v then Printf.sprintf "%d:%d" (rseg v) (roff v)
  else Felt.to_string v

let[@inline never] validate vm seg off v =
  let f = vm.seg_flag.(seg) in
  if f = k_rc || f = k_rc96 then begin
    if not (is_felt v) then fail "Range-check builtin: found non-int value at %d:%d" seg off;
    let bound = if f = k_rc then 128 else 96 in
    if not (is_small v && small_val v >= 0) && Felt.bits v > bound then
      fail "Range-check builtin: value %s at %d:%d is out of range [0, 2^%d)" (Felt.to_string v) seg off bound
  end
  else if f = k_ecdsa then fail "ecdsa builtin is not supported by this VM (write at %d:%d)" seg off

let[@inline] write vm seg off v =
  if off < 0 then fail "Negative memory offset %d:%d" seg off;
  let a = Array.unsafe_get vm.segs seg in
  if off >= slen a then grow_seg vm seg off;
  let a = Array.unsafe_get vm.segs seg in
  let cur = sget a off in
  if cur = 0 then begin
    sset a off v;
    if off >= Array.unsafe_get vm.hi seg then Array.unsafe_set vm.hi seg (off + 1);
    if Array.unsafe_get vm.seg_flag seg <> 0 then validate vm seg off v
  end
  else if not (Felt.equal cur v) then
    fail "Inconsistent memory assignment at address %d:%d. %s != %s" seg off (value_to_string cur)
      (value_to_string v)

let write_checked vm seg off v =
  if not (seg_ok vm seg) then fail "Unknown memory segment %d" seg;
  write vm seg off v

(* last assigned offset + 1 *)
let used_size vm seg = vm.hi.(seg)

(* ---------------- value arithmetic (MaybeRelocatable) ---------------- *)

let max_off = off_mask

(* relocatable + felt; the field sum must be a small offset *)
let[@inline] reloc_add_felt r f =
  if is_small f then begin
    let o = roff r + small_val f in
    if o < 0 || o > max_off then fail "Offset exceeds range when adding felt to relocatable";
    reloc (rseg r) o
  end
  else begin
    (* field sum of offset and a big felt fits only if it wraps to a small offset *)
    let s = Felt.add (small (roff r)) f in
    if is_small s && small_val s >= 0 && small_val s <= max_off then reloc (rseg r) (small_val s)
    else fail "Offset exceeds range when adding felt to relocatable"
  end

let value_add a b =
  if is_felt a then begin
    if is_felt b then Felt.add a b else reloc_add_felt b a
  end
  else if is_felt b then reloc_add_felt a b
  else fail "Cannot add two relocatable values"

let value_mul a b =
  if is_felt a && is_felt b then Felt.mul a b
  else fail "Cannot multiply relocatable values (ComputeResRelocatableMul)"

(* Rust's MaybeRelocatable::sub *)
let value_sub a b =
  if is_felt a then begin
    if is_felt b then Felt.sub a b else fail "Cannot subtract a relocatable from a felt"
  end
  else if is_felt b then begin
    if is_small b then begin
      let o = roff a - small_val b in
      if o < 0 || o > max_off then fail "Offset underflow when subtracting felt from relocatable";
      reloc (rseg a) o
    end
    else begin
      let s = Felt.sub (small (roff a)) b in
      if is_small s && small_val s >= 0 && small_val s <= max_off then reloc (rseg a) (small_val s)
      else fail "Offset underflow when subtracting felt from relocatable"
    end
  end
  else if rseg a = rseg b then small (roff a - roff b)
  else fail "Cannot subtract relocatables from different segments"

(* ---------------- builtin deduction ---------------- *)

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

(* ---------------- instruction decoding ---------------- *)

(* Packed decoded instruction (non-zero):
   bits 0..15 off0+2^15, 16..31 off1+2^15, 32..47 off2+2^15,
   48 dst_fp, 49 op0_fp, 50..51 op1 (0 op0,1 imm,2 fp,3 ap),
   52..53 res (0 op1,1 add,2 mul,3 unconstrained),
   54..55 pc (0 regular,1 jump,2 jump_rel,3 jnz),
   56..57 ap (0 regular,1 add,2 add1,3 add2),
   58..59 opcode (0 nop,1 call,2 ret,3 assert_eq),
   60 valid *)

let decode_word (w : Z.t) =
  if Z.geq w (Z.shift_left Z.one 63) then begin
    let ext = Z.shift_right w 63 in
    if Z.lt ext (Z.of_int 4) then
      fail "Unsupported opcode extension %s (Blake/QM31 are not implemented)" (Z.to_string ext)
    else fail "Invalid opcode extension %s" (Z.to_string ext)
  end;
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
  if op1c = 1 && off2 <> 0x8001 then fail "Invalid immediate offset (op1 immediate requires off2 = 1)";
  off0 lor (off1 lsl 16) lor (off2 lsl 32) lor (dst lsl 48) lor (op0 lsl 49) lor (op1c lsl 50) lor (resc lsl 52)
  lor (pcc lsl 54) lor (apc lsl 56) lor (opcc lsl 58) lor (1 lsl 60)

let decode_at vm seg off =
  let v = get vm seg off in
  if v = 0 then fail "Instruction at %d:%d is not assigned (UnknownMemoryCell)" seg off;
  if not (is_felt v) then fail "Instruction at %d:%d is a relocatable value" seg off;
  decode_word (Felt.to_z v)

let[@inline never] fetch_slow vm =
  if vm.pc_seg = 0 then begin
    if vm.pc >= Array.length vm.icache then begin
      let n = ref (max 64 (Array.length vm.icache)) in
      while !n <= vm.pc do
        n := 2 * !n
      done;
      let na = Array.make !n 0 in
      Array.blit vm.icache 0 na 0 (Array.length vm.icache);
      vm.icache <- na
    end;
    let d = decode_at vm 0 vm.pc in
    vm.icache.(vm.pc) <- d;
    d
  end
  else decode_at vm vm.pc_seg vm.pc

(* ---------------- step ---------------- *)

let[@inline never] trace_grow vm =
  vm.trace <- seg_grow vm.trace (2 * slen vm.trace)

(* Pack common register triples with low bit 1. A full triple starts
   with a relocatable PC code, whose low bit is always 0.
   Keep this layout in sync with cvm_write_trace. *)
let[@inline] record_trace vm pc_seg pc ap fp =
  let i = vm.tlen in
  if i + 3 > slen vm.trace then trace_grow vm;
  let t = vm.trace in
  if pc_seg = 0 && pc lsr 16 = 0 && (ap lor fp) lsr 23 = 0 then begin
    sset t i ((pc lsl 47) lor (ap lsl 24) lor (fp lsl 1) lor 1);
    vm.tlen <- i + 1
  end else begin
    sset t i (reloc pc_seg pc);
    sset t (i + 1) ap;
    sset t (i + 2) fp;
    vm.tlen <- i + 3
  end

let[@inline never] missing what seg off = fail "Failed to compute operand %s at %d:%d" what seg off

let[@inline never] slow_operand_read vm seg off = if seg_ok vm seg then read vm seg off else fail "Unknown segment %d" seg

let rec step_instr vm d =
  let pc_seg = vm.pc_seg and pc = vm.pc and ap = vm.ap and fp = vm.fp in
  if vm.trace_on then record_trace vm pc_seg pc ap fp;
  let off0 = (d land 0xffff) - 0x8000 in
  let off1 = ((d lsr 16) land 0xffff) - 0x8000 in
  let off2 = ((d lsr 32) land 0xffff) - 0x8000 in
  let dst_addr = (if d land (1 lsl 48) <> 0 then fp else ap) + off0 in
  let op0_addr = (if d land (1 lsl 49) <> 0 then fp else ap) + off1 in
  if dst_addr < 0 || op0_addr < 0 then fail "Negative operand address";
  let exec = Array.unsafe_get vm.segs 1 in
  let elen = slen exec in
  let dst = if dst_addr < elen then sget exec dst_addr else 0 in
  let op0 = if op0_addr < elen then sget exec op0_addr else 0 in
  (* op1 address *)
  let op1_src = (d lsr 50) land 3 in
  let op1_seg, op1_off =
    match op1_src with
    | 0 ->
        if op0 = 0 then missing "op0" 1 op0_addr;
        if not (is_reloc op0) then fail "op1 source is op0, but op0 is not a relocatable";
        (rseg op0, roff op0 + off2)
    | 1 -> (pc_seg, pc + off2)
    | 2 -> (1, fp + off2)
    | _ -> (1, ap + off2)
  in
  if op1_off < 0 then fail "Negative op1 address";
  let op1 = if op1_seg = 1 then (if op1_off < elen then sget exec op1_off else 0) else slow_operand_read vm op1_seg op1_off in
  let size = if op1_src = 1 then 2 else 1 in
  let res_kind = (d lsr 52) land 3 in
  let opcode = (d lsr 58) land 3 in
  if dst <> 0 && op0 <> 0 && op1 <> 0 then begin
    (* fast path: all operands assigned *)
    let res =
      match res_kind with
      | 0 -> op1
      | 1 -> if both_small op0 op1 then Felt.add op0 op1 else value_add op0 op1
      | 2 -> value_mul op0 op1
      | _ -> 0
    in
    (match opcode with
    | 3 -> if res = 0 then fail "UnconstrainedResAssertEq" else if not (Felt.equal res dst) then
          fail "An ASSERT_EQ instruction failed: %s != %s." (value_to_string res) (value_to_string dst)
    | 1 ->
        if op0 <> reloc pc_seg (pc + size) then fail "Call failed to write return-pc (inconsistent op0)";
        if dst <> reloc 1 fp then fail "Call failed to write return-fp (inconsistent dst)"
    | _ -> ());
    update vm d pc_seg pc ap fp size dst op1 res opcode
  end
  else slow_step vm d pc_seg pc ap fp size dst_addr op0_addr op1_seg op1_off dst op0 op1 res_kind opcode

and[@inline never] slow_step vm d pc_seg pc ap fp size dst_addr op0_addr op1_seg op1_off dst op0 op1 res_kind
    opcode =
  let res = ref 0 in
  let ded0 = op0 = 0 and ded1 = op1 = 0 and dedd = dst = 0 in
  let op0 =
    if op0 <> 0 then op0
    else begin
      let b = deduce_cell vm 1 op0_addr in
      if b <> 0 then b
      else begin
        let v =
          match opcode with
          | 1 -> reloc pc_seg (pc + size)
          | 3 -> (
              match res_kind with
              | 1 ->
                  if dst <> 0 && op1 <> 0 then begin
                    res := dst;
                    value_sub dst op1
                  end
                  else 0
              | 2 ->
                  if dst <> 0 && op1 <> 0 && is_felt dst && is_felt op1 && op1 <> zero then begin
                    res := dst;
                    match Felt.div dst op1 with Some q -> q | None -> 0
                  end
                  else 0
              | _ -> 0)
          | _ -> 0
        in
        if v = 0 then missing "op0" 1 op0_addr;
        v
      end
    end
  in
  let op1 =
    if op1 <> 0 then op1
    else begin
      let b = deduce_cell vm op1_seg op1_off in
      if b <> 0 then b
      else begin
        let v, r =
          if opcode = 3 then
            match res_kind with
            | 0 -> (dst, dst)
            | 1 -> ((if dst <> 0 then (try value_sub dst op0 with Vm_error _ -> 0) else 0), dst)
            | 2 ->
                if dst <> 0 && is_felt dst && is_felt op0 && op0 <> zero then
                  ((match Felt.div dst op0 with Some q -> q | None -> 0), dst)
                else (0, 0)
            | _ -> (0, 0)
          else (0, 0)
        in
        if !res = 0 then res := r;
        if v = 0 then missing "op1" op1_seg op1_off;
        v
      end
    end
  in
  if !res = 0 then
    res :=
      (match res_kind with
      | 0 -> op1
      | 1 -> value_add op0 op1
      | 2 -> value_mul op0 op1
      | _ -> 0);
  let res = !res in
  let dst =
    if dst <> 0 then dst
    else
      match opcode with
      | 3 -> if res = 0 then fail "NoDst" else res
      | 1 -> reloc 1 fp
      | _ -> fail "NoDst: couldn't deduce dst"
  in
  if ded0 then write_checked vm 1 op0_addr op0;
  if ded1 then write_checked vm op1_seg op1_off op1;
  if dedd then write_checked vm 1 dst_addr dst;
  (match opcode with
  | 3 ->
      if res = 0 then fail "UnconstrainedResAssertEq"
      else if not (Felt.equal res dst) then
        fail "An ASSERT_EQ instruction failed: %s != %s." (value_to_string res) (value_to_string dst)
  | 1 ->
      if not (Felt.equal op0 (reloc pc_seg (pc + size))) then fail "Call failed to write return-pc (inconsistent op0)";
      if not (Felt.equal dst (reloc 1 fp)) then fail "Call failed to write return-fp (inconsistent dst)"
  | _ -> ());
  update vm d pc_seg pc ap fp size dst op1 res opcode

and[@inline] update vm d pc_seg pc ap fp size dst op1 res opcode =
  (* fp *)
  let new_fp =
    match opcode with
    | 1 -> ap + 2
    | 2 ->
        if is_reloc dst then roff dst
        else
          let n = Felt.to_nat dst in
          if n < 0 then fail "fp update: dst does not fit an offset" else n
    | _ -> fp
  in
  (* ap *)
  let new_ap =
    match (d lsr 56) land 3 with
    | 0 -> ap
    | 1 ->
        if res = 0 then fail "UnconstrainedResAdd: ap += res with unconstrained res";
        if not (is_felt res) then fail "ap += res requires an integer res";
        roff (reloc_add_felt (reloc 1 ap) res)
    | 2 -> ap + 1
    | _ -> ap + 2
  in
  (* pc *)
  (match (d lsr 54) land 3 with
  | 0 -> vm.pc <- pc + size
  | 1 ->
      if res = 0 || not (is_reloc res) then fail "Jump requires a relocatable res";
      vm.pc_seg <- rseg res;
      vm.pc <- roff res
  | 2 ->
      if res = 0 || not (is_felt res) then fail "Relative jump requires an integer res";
      if is_small res then begin
        let o = pc + small_val res in
        if o < 0 then fail "pc offset underflow";
        vm.pc <- o
      end
      else vm.pc <- roff (reloc_add_felt (reloc pc_seg pc) res)
  | _ ->
      if dst = zero then vm.pc <- pc + size
      else begin
        if not (is_felt op1) then fail "jnz requires an integer op1";
        if is_small op1 then begin
          let o = pc + small_val op1 in
          if o < 0 then fail "pc offset underflow";
          vm.pc <- o
        end
        else vm.pc <- roff (reloc_add_felt (reloc pc_seg pc) op1)
      end);
  vm.fp <- new_fp;
  vm.ap <- new_ap;
  vm.steps <- vm.steps + 1

let[@inline] step vm =
  let d =
    if vm.pc_seg = 0 && vm.pc < Array.length vm.icache then
      let d = Array.unsafe_get vm.icache vm.pc in
      if d <> 0 then d else fetch_slow vm
    else fetch_slow vm
  in
  step_instr vm d

(* ---------------- fast interpreter loop ----------------

   Registers live in locals.  Each iteration either executes the instruction
   entirely on the fast path, or (before any mutation) falls back to the
   generic [step] above, which implements the full deduction semantics.
   Program counters carrying hints are flagged in the decoded cache, so the
   fast path pays one load per step for hint detection. *)

let hint_bit = 1 lsl 61
let generic_steps = ref 0
let hint_steps = ref 0

external cpu_batch : int array -> int array -> seg array -> int array -> int array ->
  seg -> bytes -> int -> bool -> int array -> int array -> int = "cvm_cpu_batch_byte" "cvm_cpu_batch" [@@noalloc]

let run_fast vm (hints : (vm -> unit) array array) end_seg =
  let nh = Array.length hints in
  let pc = ref vm.pc and ap = ref vm.ap and fp = ref vm.fp and pc_seg = ref vm.pc_seg in
  let steps = ref vm.steps in
  let hi1 = ref vm.hi.(1) in
  let pedersen = List.find_opt (fun b -> b.kind = Pedersen) vm.builtins in
  let registers = Array.make 9 0 and spans = Array.make nh 0 in
  while not (!pc_seg = end_seg && !pc = 0) do
    if !pc_seg = 0 && end_seg <> 0 then begin
      registers.(0) <- !pc; registers.(1) <- !ap; registers.(2) <- !fp;
      registers.(3) <- !hi1; registers.(4) <- vm.tlen; registers.(5) <- !pool_n;
      let count = cpu_batch registers vm.icache vm.segs vm.seg_flag vm.hi vm.trace
        !pool vm.nsegs vm.trace_on spans (match pedersen with Some b -> b.cache | None -> [||]) in
      pc := registers.(0); ap := registers.(1); fp := registers.(2);
      hi1 := registers.(3); vm.tlen <- registers.(4); pool_n := registers.(5);
      steps := !steps + count
    end;
    let ic = vm.icache in
    let d = if !pc_seg = 0 && !pc < Array.length ic then Array.unsafe_get ic !pc else 0 in
    let hints_done = d land hint_bit <> 0 in
    let d =
      if hints_done then begin
        (* hints cannot move registers: run them, then execute on the fast path *)
        vm.pc <- !pc;
        vm.ap <- !ap;
        vm.fp <- !fp;
        vm.pc_seg <- !pc_seg;
        vm.steps <- !steps;
        if !hi1 > vm.hi.(1) then vm.hi.(1) <- !hi1;
        let hs = Array.unsafe_get hints !pc in
        for i = 0 to Array.length hs - 1 do
          (Array.unsafe_get hs i) vm
        done;
        hi1 := vm.hi.(1);
        d land lnot hint_bit
      end
      else d
    in
    let fast = ref false in
    if d <> 0 then begin
      let pcv = !pc and apv = !ap and fpv = !fp in
      let off0 = (d land 0xffff) - 0x8000 in
      let off1 = ((d lsr 16) land 0xffff) - 0x8000 in
      let off2 = ((d lsr 32) land 0xffff) - 0x8000 in
      let dst_addr = (if d land (1 lsl 48) <> 0 then fpv else apv) + off0 in
      let op0_addr = (if d land (1 lsl 49) <> 0 then fpv else apv) + off1 in
      let mem = Array.unsafe_get vm.segs 1 in
      let len = slen mem in
      if dst_addr >= 0 && op0_addr >= 0 && dst_addr < len - 2 then begin
        let op0 = if op0_addr < len then sget mem op0_addr else 0 in
        let src = (d lsr 50) land 3 in
        let op1 =
          match src with
          | 1 ->
              let prog = Array.unsafe_get vm.segs 0 in
              let a = pcv + 1 in
              if a < slen prog then sget prog a else 0
          | 2 -> let a = fpv + off2 in if a >= 0 && a < len then sget mem a else 0
          | 3 -> let a = apv + off2 in if a >= 0 && a < len then sget mem a else 0
          | _ ->
              if op0 land 3 = 2 then begin
                let sg = rseg op0 and a = roff op0 + off2 in
                if sg >= 0 && sg < vm.nsegs && a >= 0 then begin
                  let sm = Array.unsafe_get vm.segs sg in
                  let v = if a < slen sm then sget sm a else 0 in
                  (* op1 deduction for `[ptr + k] = dst` into a non-deducing segment *)
                  if v = 0 && dst_addr < len && (d lsr 58) land 3 = 3 && (d lsr 52) land 3 = 0
                     && not (is_deducing (Array.unsafe_get vm.seg_flag sg)) then begin
                    let dv = sget mem dst_addr in
                    if dv <> 0 then (write vm sg a dv; dv) else 0
                  end
                  else if v = 0 && is_deducing (Array.unsafe_get vm.seg_flag sg) then begin
                    (* builtin auto-deduction of the op1 cell, as cairo-vm does first *)
                    let b = deduce_cell vm sg a in
                    if b <> 0 then (write vm sg a b; b) else 0
                  end
                  else v
                end
                else 0
              end
              else 0
        in
        let size = if src = 1 then 2 else 1 in
        let opcode = (d lsr 58) land 3 in
        let dst = sget mem dst_addr in
        if op1 <> 0 then begin
          (* ---- result ---- *)
          let res_kind = (d lsr 52) land 3 in
          let res =
            match res_kind with
            | 0 -> op1
            | 1 ->
                if op0 = 0 then 0
                else if both_small op0 op1 then begin
                  let s = (op0 asr 2) + (op1 asr 2) in
                  if fits_small s then small s else Felt.add op0 op1
                end
                else if is_reloc op0 && is_small op1 then begin
                  let o = roff op0 + small_val op1 in
                  if o >= 0 && o <= max_off then reloc (rseg op0) o else 0
                end
                else if is_felt op0 && is_felt op1 then Felt.add op0 op1
                else 0
            | 2 -> if op0 <> 0 && is_felt op0 && is_felt op1 then Felt.mul op0 op1 else 0
            | _ -> -1 (* unconstrained *)
          in
          let ok =
            match opcode with
            | 3 ->
                if res = 0 || res = -1 || op0 = 0 then false
                else if dst = 0 then begin
                  sset mem dst_addr res;
                  if dst_addr >= !hi1 then hi1 := dst_addr + 1;
                  true
                end
                else Felt.equal dst res
            | 1 ->
                (* call: [ap] = fp, [ap+1] = return pc *)
                let ret = reloc 0 (pcv + size) and fpr = reloc 1 fpv in
                if !pc_seg <> 0 || res = 0 then false
                else begin
                  let o0 = op0 in
                  if (dst = 0 || dst = fpr) && (o0 = 0 || o0 = ret) then begin
                    if dst = 0 then sset mem dst_addr fpr;
                    if o0 = 0 then sset mem op0_addr ret;
                    if op0_addr >= !hi1 then hi1 := op0_addr + 1;
                    true
                  end
                  else false
                end
            | _ -> dst <> 0 && op0 <> 0 (* NOP/RET: cairo-vm requires dst and op0 *)
          in
          if ok then begin
            (* ---- register updates ---- *)
            let dstv = if opcode = 3 && dst = 0 then res else if opcode = 1 && dst = 0 then reloc 1 fpv else dst in
            let new_fp =
              match opcode with
              | 1 -> apv + 2
              | 2 -> if is_reloc dstv then roff dstv else if is_small dstv && small_val dstv >= 0 then small_val dstv else -1
              | _ -> fpv
            in
            let new_ap =
              match (d lsr 56) land 3 with
              | 0 -> apv
              | 1 -> if is_small res then apv + small_val res else -1
              | 2 -> apv + 1
              | _ -> apv + 2
            in
            let pcu = (d lsr 54) land 3 in
            let new_pc, new_seg =
              match pcu with
              | 0 -> (pcv + size, !pc_seg)
              | 1 -> if res > 0 && is_reloc res then (roff res, rseg res) else (-1, 0)
              | 2 -> if is_small res then (pcv + small_val res, !pc_seg) else (-1, 0)
              | _ ->
                  if dstv = zero then (pcv + size, !pc_seg)
                  else if is_small op1 then (pcv + small_val op1, !pc_seg)
                  else (-1, 0)
            in
            if new_fp >= 0 && new_ap >= 0 && new_pc >= 0 then begin
              if vm.trace_on then record_trace vm !pc_seg pcv apv fpv;
              pc := new_pc;
              pc_seg := new_seg;
              ap := new_ap;
              fp := new_fp;
              incr steps;
              fast := true
            end
            else if opcode = 3 && dst = 0 then
              (* we already wrote dst; generic step will see it assigned and recompute identically *)
              ()
          end
        end
      end
    end;
    if hints_done then incr hint_steps;
    if not !fast then begin
      incr generic_steps;
      vm.pc <- !pc;
      vm.ap <- !ap;
      vm.fp <- !fp;
      vm.pc_seg <- !pc_seg;
      vm.steps <- !steps;
      if !hi1 > vm.hi.(1) then vm.hi.(1) <- !hi1;
      if (not hints_done) && !pc_seg = 0 && !pc < nh then begin
        let hs = Array.unsafe_get hints !pc in
        for i = 0 to Array.length hs - 1 do
          (Array.unsafe_get hs i) vm
        done
      end;
      step vm;
      (* flag hint pcs in the decoded cache *)
      if !pc_seg = 0 && !pc < nh && Array.length (Array.unsafe_get hints !pc) <> 0 then begin
        let p0 = !pc in
        if p0 < Array.length vm.icache && vm.icache.(p0) <> 0 then vm.icache.(p0) <- vm.icache.(p0) lor hint_bit
      end;
      pc := vm.pc;
      ap := vm.ap;
      fp := vm.fp;
      pc_seg := vm.pc_seg;
      steps := vm.steps;
      hi1 := vm.hi.(1)
    end
  done;
  if !hi1 > vm.hi.(1) then vm.hi.(1) <- !hi1;
  vm.pc <- !pc;
  vm.ap <- !ap;
  vm.fp <- !fp;
  vm.pc_seg <- !pc_seg;
  vm.steps <- !steps
