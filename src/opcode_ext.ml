(* Stwo opcode extensions of cairo-vm v3.2.0: Blake, BlakeFinalize and
   QM31Operation.

   Decoding (Vm.decode_word) already enforces the extension flag rules, so an
   instruction reaching [step] is
     - Blake / BlakeFinalize: NOP, res = op1, op1 from fp or ap, regular pc,
       ap regular or +1;
     - QM31Operation: ASSERT_EQ, res = add or mul, op1 from imm, fp or ap,
       regular pc, ap regular or +1.

   Operands are computed exactly as in VirtualMachine::compute_operands with
   the typed operations of typed_operations.rs: missing op0/op1 are first
   deduced by the owning builtin, then by the (typed) inverse rules; dst is
   deduced from res for ASSERT_EQ only.  Executable cross-check:
   cairo-vm-lean CairoVM/Execution/{Blake,BlakeFinalize,QM31,Dispatch}.lean. *)

open Vm

(* ---------------- QM31 ---------------- *)

(* M31 coordinates; a QM31 element is (a + b i) + (c + d i) j with i^2 = -1,
   j^2 = 2 + i, packed into a felt as a + b 2^36 + c 2^72 + d 2^108. *)
let m31 = (1 lsl 31) - 1
let md x = let r = x mod m31 in if r < 0 then r + m31 else r
let ( +% ) a b = md (a + b)
let ( -% ) a b = md (a - b)
let ( *% ) a b = md (a * b) (* operands < 2^31: product < 2^62 *)

let rec m31_pow b e = if e = 0 then 1 else
  let h = m31_pow (b *% b) (e / 2) in if e land 1 = 1 then h *% b else h

let m31_inv x = m31_pow x (m31 - 2)

let radix_bits = 36
let bound_144 = Z.shift_left Z.one 144

(* QM31::unpack_from_felt: the felt must be < 2^144 and every 36-bit limb a
   reduced M31 coordinate. *)
let unpack v =
  if not (Felt.is_felt v) then fail "QM31 operation on a relocatable value";
  let z = Felt.to_z v in
  if Z.geq z bound_144 then fail "QM31 operand %s is not a reduced packed QM31 element" (Z.to_string z);
  let limb k = Z.to_int (Z.extract z (k * radix_bits) radix_bits) in
  let c = Array.init 4 limb in
  Array.iter (fun x -> if x >= m31 then fail "QM31 operand %s is not a reduced packed QM31 element" (Z.to_string z)) c;
  c

let pack (c : int array) =
  let z = ref Z.zero in
  for k = 3 downto 0 do
    z := Z.add (Z.shift_left !z radix_bits) (Z.of_int c.(k))
  done;
  Felt.of_z !z

let q_add x y = Array.init 4 (fun k -> x.(k) +% y.(k))
let q_sub x y = Array.init 4 (fun k -> x.(k) -% y.(k))

(* schoolbook product modulo i^2 + 1, j^2 - (2 + i) *)
let q_mul x y =
  let a = x.(0) and b = x.(1) and c = x.(2) and d = x.(3) in
  let e = y.(0) and f = y.(1) and g = y.(2) and h = y.(3) in
  let cg_dh = (c *% g) -% (d *% h) and ch_dg = (c *% h) +% (d *% g) in
  [|
    (a *% e) -% (b *% f) +% (2 *% cg_dh) -% ch_dg;
    (a *% f) +% (b *% e) +% cg_dh +% (2 *% ch_dg);
    (a *% g) -% (b *% h) +% (c *% e) -% (d *% f);
    (a *% h) +% (b *% g) +% (c *% f) +% (d *% e);
  |]

(* y^-1 = (lo - hi j) / (lo^2 - hi^2 (2 + i)); None for zero. *)
let q_inv y =
  let cmul (a, b) (c, d) = ((a *% c) -% (b *% d), (a *% d) +% (b *% c)) in
  let lo = (y.(0), y.(1)) and hi = (y.(2), y.(3)) in
  let hh = cmul hi hi in
  let nr, ni = cmul lo lo in
  let tr, ti = cmul hh (2, 1) in
  let nr = nr -% tr and ni = ni -% ti in
  let n2 = (nr *% nr) +% (ni *% ni) in
  if n2 = 0 then None
  else begin
    let k = m31_inv n2 in
    let ir = nr *% k and ii = md (- (ni *% k)) in
    let a, b = cmul lo (ir, ii) in
    let c, d = cmul (md (- (fst hi)), md (- (snd hi))) (ir, ii) in
    Some [| a; b; c; d |]
  end

let q_div x y = match q_inv y with Some yi -> q_mul x yi | None -> fail "QM31 division by zero"

let typed_add a b = pack (q_add (unpack a) (unpack b))
let typed_sub a b = pack (q_sub (unpack a) (unpack b))
let typed_mul a b = pack (q_mul (unpack a) (unpack b))
let typed_div a b = pack (q_div (unpack a) (unpack b))

(* ---------------- shared operand plumbing ---------------- *)

let operand_or_builtin vm seg off v = if v <> 0 then v else deduce_cell vm seg off

let read_u32 vm seg off =
  let v = get vm seg off in
  if v = 0 then fail "Unknown memory cell %d:%d (Blake2s operand)" seg off;
  if not (Felt.is_felt v) then fail "Expected integer at %d:%d (Blake2s operand)" seg off;
  let n = Felt.to_nat v in
  if n < 0 || n > 0xFFFFFFFF then fail "Blake2s operand at %d:%d does not fit in 32 bits" seg off;
  n

let read_ptr vm seg off what =
  let v = get vm seg off in
  if v = 0 then fail "Unknown memory cell %d:%d (Blake2s %s)" seg off what;
  if not (Felt.is_reloc v) then fail "Expected relocatable at %d:%d (Blake2s %s)" seg off what;
  v

let u32_range vm ptr n = Array.init n (fun i -> read_u32 vm (Felt.rseg ptr) (Felt.roff ptr + i))

let finish vm d pc ap size =
  vm.ap <- (match (d lsr 56) land 3 with 0 -> ap | 2 -> ap + 1 | _ -> fail "Invalid ap update for opcode extension");
  vm.pc <- pc + size;
  vm.steps <- vm.steps + 1

let step vm d =
  let ext = (d lsr ext_shift) land 3 in
  let pc_seg = vm.pc_seg and pc = vm.pc and ap = vm.ap and fp = vm.fp in
  let off0 = (d land 0xffff) - 0x8000 in
  let off1 = ((d lsr 16) land 0xffff) - 0x8000 in
  let off2 = ((d lsr 32) land 0xffff) - 0x8000 in
  let dst_addr = (if d land (1 lsl 48) <> 0 then fp else ap) + off0 in
  let op0_addr = (if d land (1 lsl 49) <> 0 then fp else ap) + off1 in
  if dst_addr < 0 || op0_addr < 0 then fail "Negative operand address";
  let op1_seg, op1_off =
    match (d lsr 50) land 3 with
    | 1 -> (pc_seg, pc + off2)
    | 2 -> (1, fp + off2)
    | 3 -> (1, ap + off2)
    | _ -> fail "Opcode extension with op1 addressed through op0"
  in
  if op1_off < 0 then fail "Negative op1 address";
  let size = if (d lsr 50) land 3 = 1 then 2 else 1 in
  let dst = read vm 1 dst_addr and op0 = read vm 1 op0_addr and op1 = get vm op1_seg op1_off in
  if vm.trace_on then record_trace vm pc_seg pc ap fp;
  match ext with
  | 1 | 2 ->
      (* NOP with res = op1: only builtin deduction can supply operands *)
      let op0' = operand_or_builtin vm 1 op0_addr op0 in
      if op0' = 0 then fail "Failed to compute operand op0 at 1:%d" op0_addr;
      let op1' = operand_or_builtin vm op1_seg op1_off op1 in
      if op1' = 0 then fail "Failed to compute operand op1 at %d:%d" op1_seg op1_off;
      if dst = 0 then fail "NoDst: couldn't deduce dst";
      if op0 = 0 then write_checked vm 1 op0_addr op0';
      if op1 = 0 then write_checked vm op1_seg op1_off op1';
      (* handle_blake2s_instruction *)
      if not (Felt.is_felt dst) then fail "Expected integer at 1:%d (Blake2s counter)" dst_addr;
      let counter = Felt.to_nat dst in
      if counter < 0 || counter > 0xFFFFFFFF then fail "Blake2s counter at 1:%d does not fit in 32 bits" dst_addr;
      let state_ptr = read_ptr vm 1 op0_addr "state pointer" in
      let state = u32_range vm state_ptr 8 in
      let msg_ptr = read_ptr vm op1_seg op1_off "message pointer" in
      let message = u32_range vm msg_ptr 16 in
      let out = read_ptr vm 1 ap "output pointer" in
      let f0 = if ext = 2 then 0xFFFFFFFF else 0 in
      let h = Hints.blake2s_compress state message counter 0 f0 0 in
      Array.iteri (fun i w -> write_checked vm (Felt.rseg out) (Felt.roff out + i) (Felt.small w)) h;
      finish vm d pc ap size
  | 3 ->
      let mul = (d lsr 52) land 3 = 2 in
      let res = ref 0 in
      let op0' =
        if op0 <> 0 then op0
        else begin
          let b = deduce_cell vm 1 op0_addr in
          if b <> 0 then b
          else begin
            let v =
              if dst = 0 || op1 = 0 then 0
              else if not mul then (res := dst; typed_sub dst op1)
              else if Felt.is_felt dst && Felt.is_felt op1 && not (Felt.equal op1 Felt.zero) then
                (res := dst; typed_div dst op1)
              else 0
            in
            if v = 0 then fail "Failed to compute operand op0 at 1:%d" op0_addr;
            v
          end
        end
      in
      let op1' =
        if op1 <> 0 then op1
        else begin
          let b = deduce_cell vm op1_seg op1_off in
          if b <> 0 then b
          else begin
            let v =
              if not mul then begin
                if !res = 0 then res := dst;
                if dst = 0 then 0 else (try typed_sub dst op0' with Vm_error _ -> 0)
              end
              else if dst <> 0 && Felt.is_felt dst && Felt.is_felt op0' && not (Felt.equal op0' Felt.zero) then begin
                if !res = 0 then res := dst;
                typed_div dst op0'
              end
              else 0
            in
            if v = 0 then fail "Failed to compute operand op1 at %d:%d" op1_seg op1_off;
            v
          end
        end
      in
      let res = if !res <> 0 then !res else if mul then typed_mul op0' op1' else typed_add op0' op1' in
      let dst' = if dst <> 0 then dst else res in
      if op0 = 0 then write_checked vm 1 op0_addr op0';
      if op1 = 0 then write_checked vm op1_seg op1_off op1';
      if dst = 0 then write_checked vm 1 dst_addr dst';
      if not (Felt.equal res dst') then
        fail "An ASSERT_EQ instruction failed: %s != %s." (value_to_string res) (value_to_string dst');
      finish vm d pc ap size
  | _ -> fail "Invalid opcode extension %d" ext

let install () = Vm.ext_step := step
