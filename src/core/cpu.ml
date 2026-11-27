open Felt
open Errors
open Segment
open Builtin
open Instruction
open Vm
open Deduce

let decode_at vm seg off =
  let v = get vm seg off in
  if v = Felt.empty then fail "Instruction at %d:%d is not assigned (UnknownMemoryCell)" seg off;
  if not (is_felt v) then fail "Instruction at %d:%d is a relocatable value" seg off;
  let z = Felt.to_z v in
  try decode_word z
  with Generic_instruction -> fail "Unsupported generic instruction at pc %d:%d: 0x%s" seg off (Z.format "%x" z)

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
    if d land ext_mask = 0 then vm.icache.(vm.pc) <- d;
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
    raw_set t i ((pc lsl 47) lor (ap lsl 24) lor (fp lsl 1) lor 1);
    vm.tlen <- i + 1
  end else begin
    raw_set t i (reloc pc_seg pc :> int);
    raw_set t (i + 1) ap;
    raw_set t (i + 2) fp;
    vm.tlen <- i + 3
  end

let[@inline never] missing what seg off = fail "Failed to compute operand %s at %d:%d" what seg off

let[@inline never] slow_operand_read vm seg off =
  if seg_ok vm seg then read vm seg off
  else if seg < 0 then temp_read vm seg off
  else fail "Unknown segment %d" seg

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
  let dst = if dst_addr < elen then sget exec dst_addr else Felt.empty in
  let op0 = if op0_addr < elen then sget exec op0_addr else Felt.empty in
  (* with relocation rules, operands are read through Memory.get *)
  let dst = if vm.relocating then relocate_temp_value vm dst else dst in
  let op0 = if vm.relocating then relocate_temp_value vm op0 else op0 in
  (* op1 address *)
  let op1_src = (d lsr 50) land 3 in
  let op1_seg, op1_off =
    match op1_src with
    | 0 ->
        if op0 = Felt.empty then missing "op0" 1 op0_addr;
        if not (is_reloc op0) then fail "op1 source is op0, but op0 is not a relocatable";
        (rseg op0, roff op0 + off2)
    | 1 -> (pc_seg, pc + off2)
    | 2 -> (1, fp + off2)
    | _ -> (1, ap + off2)
  in
  if op1_off < 0 then fail "Negative op1 address";
  let op1 = if op1_seg = 1 then (if op1_off < elen then sget exec op1_off else Felt.empty) else slow_operand_read vm op1_seg op1_off in
  let op1 = if vm.relocating then relocate_temp_value vm op1 else op1 in
  let size = if op1_src = 1 then 2 else 1 in
  let res_kind = (d lsr 52) land 3 in
  let opcode = (d lsr 58) land 3 in
  if dst <> Felt.empty && op0 <> Felt.empty && op1 <> Felt.empty then begin
    (* fast path: all operands assigned *)
    let res =
      match res_kind with
      | 0 -> op1
      | 1 -> if both_small op0 op1 then Felt.add op0 op1 else value_add op0 op1
      | 2 -> value_mul op0 op1
      | _ -> Felt.empty
    in
    (match opcode with
    | 3 -> if res = Felt.empty then fail "UnconstrainedResAssertEq" else if not (Felt.equal res dst) then
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
  let res = ref Felt.empty in
  let ded0 = op0 = Felt.empty and ded1 = op1 = Felt.empty and dedd = dst = Felt.empty in
  let op0 =
    if op0 <> Felt.empty then op0
    else begin
      let b = deduce_cell vm 1 op0_addr in
      if b <> Felt.empty then b
      else begin
        let v =
          match opcode with
          | 1 -> reloc pc_seg (pc + size)
          | 3 -> (
              match res_kind with
              | 1 ->
                  if dst <> Felt.empty && op1 <> Felt.empty then begin
                    res := dst;
                    value_sub dst op1
                  end
                  else Felt.empty
              | 2 ->
                  if dst <> Felt.empty && op1 <> Felt.empty && is_felt dst && is_felt op1 && op1 <> zero then begin
                    res := dst;
                    match Felt.div dst op1 with Some q -> q | None -> Felt.empty
                  end
                  else Felt.empty
              | _ -> Felt.empty)
          | _ -> Felt.empty
        in
        if v = Felt.empty then missing "op0" 1 op0_addr;
        v
      end
    end
  in
  let op1 =
    if op1 <> Felt.empty then op1
    else begin
      let b = deduce_cell vm op1_seg op1_off in
      if b <> Felt.empty then b
      else begin
        let v, r =
          if opcode = 3 then
            match res_kind with
            | 0 -> (dst, dst)
            | 1 -> ((if dst <> Felt.empty then (try value_sub dst op0 with Vm_error _ -> Felt.empty) else Felt.empty), dst)
            | 2 ->
                if dst <> Felt.empty && is_felt dst && is_felt op0 && op0 <> zero then
                  ((match Felt.div dst op0 with Some q -> q | None -> Felt.empty), dst)
                else (Felt.empty, Felt.empty)
            | _ -> (Felt.empty, Felt.empty)
          else (Felt.empty, Felt.empty)
        in
        if !res = Felt.empty then res := r;
        if v = Felt.empty then missing "op1" op1_seg op1_off;
        v
      end
    end
  in
  if !res = Felt.empty then
    res :=
      (match res_kind with
      | 0 -> op1
      | 1 -> value_add op0 op1
      | 2 -> value_mul op0 op1
      | _ -> Felt.empty);
  let res = !res in
  let dst =
    if dst <> Felt.empty then dst
    else
      match opcode with
      | 3 -> if res = Felt.empty then fail "NoDst" else res
      | 1 -> reloc 1 fp
      | _ -> fail "NoDst: couldn't deduce dst"
  in
  if ded0 then write_checked vm 1 op0_addr op0;
  if ded1 then write_checked vm op1_seg op1_off op1;
  if dedd then write_checked vm 1 dst_addr dst;
  (match opcode with
  | 3 ->
      if res = Felt.empty then fail "UnconstrainedResAssertEq"
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
        if res = Felt.empty then fail "UnconstrainedResAdd: ap += res with unconstrained res";
        if not (is_felt res) then fail "ap += res requires an integer res";
        roff (reloc_add_felt (reloc 1 ap) res)
    | 2 -> ap + 1
    | _ -> ap + 2
  in
  (* pc *)
  (match (d lsr 54) land 3 with
  | 0 -> vm.pc <- pc + size
  | 1 ->
      if res = Felt.empty || not (is_reloc res) then fail "Jump requires a relocatable res";
      vm.pc_seg <- rseg res;
      vm.pc <- roff res
  | 2 ->
      if res = Felt.empty || not (is_felt res) then fail "Relative jump requires an integer res";
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

(* Cached words are always Stone instructions (their bit 61 may carry
   run_fast's hint flag); extension bits are only meaningful on a fresh
   decode, since extension words are never cached. *)
let[@inline never] step_uncached vm =
  let d = fetch_slow vm in
  if d land ext_mask <> 0 then !ext_step vm d else step_instr vm d

let[@inline] step vm =
  if vm.pc_seg = 0 && vm.pc < Array.length vm.icache then begin
    let d = Array.unsafe_get vm.icache vm.pc in
    if d <> 0 then step_instr vm d else step_uncached vm
  end
  else step_uncached vm

(* ---------------- fast interpreter loop ----------------

   Registers live in locals.  Each iteration either executes the instruction
   entirely on the fast path, or (before any mutation) falls back to the
   generic [step] above, which implements the full deduction semantics.
   Program counters carrying hints are flagged in the decoded cache, so the
   fast path pays one load per step for hint detection. *)

let hint_bit = 1 lsl 61

(* Raised by [run_fast] after the hints of the current pc have run and a
   relocation rule exists. Registers are synchronized in [vm]; the caller
   continues with [run_relocating], which reads memory through the rules. *)
exception Relocating
let generic_steps = ref 0
let hint_steps = ref 0

external cpu_batch : int array -> int array -> seg array -> flag array -> int array ->
  seg -> bytes -> int -> bool -> int array -> Felt.t array -> int = "cvm_cpu_batch_byte" "cvm_cpu_batch" [@@noalloc]

(* JNZ's unconstrained result: tag 3 with an impossible pool index, so it
   never equals a real value. *)
let unconstrained = Felt.unsafe_of_int (-1)

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
        if vm.relocating then raise Relocating;
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
        let op0 = if op0_addr < len then sget mem op0_addr else Felt.empty in
        let src = (d lsr 50) land 3 in
        let op1 =
          match src with
          | 1 ->
              let prog = Array.unsafe_get vm.segs 0 in
              let a = pcv + 1 in
              if a < slen prog then sget prog a else Felt.empty
          | 2 -> let a = fpv + off2 in if a >= 0 && a < len then sget mem a else Felt.empty
          | 3 -> let a = apv + off2 in if a >= 0 && a < len then sget mem a else Felt.empty
          | _ ->
              if is_reloc op0 then begin
                let sg = rseg op0 and a = roff op0 + off2 in
                if sg >= 0 && sg < vm.nsegs && a >= 0 then begin
                  let sm = Array.unsafe_get vm.segs sg in
                  let v = if a < slen sm then sget sm a else Felt.empty in
                  (* op1 deduction for `[ptr + k] = dst` into a non-deducing segment *)
                  if v = Felt.empty && dst_addr < len && (d lsr 58) land 3 = 3 && (d lsr 52) land 3 = 0
                     && not (is_deducing (Array.unsafe_get vm.seg_flag sg)) then begin
                    let dv = sget mem dst_addr in
                    if dv <> Felt.empty then (write vm sg a dv; dv) else Felt.empty
                  end
                  else if v = Felt.empty && is_deducing (Array.unsafe_get vm.seg_flag sg) then begin
                    (* builtin auto-deduction of the op1 cell, as cairo-vm does first *)
                    let b = deduce_cell vm sg a in
                    if b <> Felt.empty then (write vm sg a b; b) else Felt.empty
                  end
                  else v
                end
                else Felt.empty
              end
              else Felt.empty
        in
        let size = if src = 1 then 2 else 1 in
        let opcode = (d lsr 58) land 3 in
        let dst = sget mem dst_addr in
        if op1 <> Felt.empty then begin
          (* ---- result ---- *)
          let res_kind = (d lsr 52) land 3 in
          let res =
            match res_kind with
            | 0 -> op1
            | 1 ->
                if op0 = Felt.empty then Felt.empty
                else if both_small op0 op1 then begin
                  let s = small_val op0 + small_val op1 in
                  if fits_small s then small s else Felt.add op0 op1
                end
                else if is_reloc op0 && is_small op1 then begin
                  let o = roff op0 + small_val op1 in
                  if o >= 0 && o <= max_off then reloc (rseg op0) o else Felt.empty
                end
                else if is_felt op0 && is_felt op1 then Felt.add op0 op1
                else Felt.empty
            | 2 -> if op0 <> Felt.empty && is_felt op0 && is_felt op1 then Felt.mul op0 op1 else Felt.empty
            | _ -> unconstrained
          in
          let ok =
            match opcode with
            | 3 ->
                if res = Felt.empty || res = unconstrained || op0 = Felt.empty then false
                else if dst = Felt.empty then begin
                  sset mem dst_addr res;
                  if dst_addr >= !hi1 then hi1 := dst_addr + 1;
                  true
                end
                else Felt.equal dst res
            | 1 ->
                (* call: [ap] = fp, [ap+1] = return pc *)
                let ret = reloc 0 (pcv + size) and fpr = reloc 1 fpv in
                if !pc_seg <> 0 || res = Felt.empty then false
                else begin
                  let o0 = op0 in
                  if (dst = Felt.empty || dst = fpr) && (o0 = Felt.empty || o0 = ret) then begin
                    if dst = Felt.empty then sset mem dst_addr fpr;
                    if o0 = Felt.empty then sset mem op0_addr ret;
                    if op0_addr >= !hi1 then hi1 := op0_addr + 1;
                    true
                  end
                  else false
                end
            | _ -> dst <> Felt.empty && op0 <> Felt.empty (* NOP/RET: cairo-vm requires dst and op0 *)
          in
          if ok then begin
            (* ---- register updates ---- *)
            let dstv = if opcode = 3 && dst = Felt.empty then res else if opcode = 1 && dst = Felt.empty then reloc 1 fpv else dst in
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
              | 1 -> if (res :> int) > 0 && is_reloc res then (roff res, rseg res) else (-1, 0)
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
            else if opcode = 3 && dst = Felt.empty then
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
        done;
        if vm.relocating then raise Relocating
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

(* Generic loop used once relocation rules exist (rare: temporary segments).
   [skip_hints] is true when the hints of the current pc already ran. *)
let run_relocating vm (hints : (vm -> unit) array array) end_seg ~skip_hints =
  let nh = Array.length hints in
  let skip = ref skip_hints in
  while not (vm.pc_seg = end_seg && vm.pc = 0) do
    if (not !skip) && vm.pc_seg = 0 && vm.pc < nh then begin
      let hs = Array.unsafe_get hints vm.pc in
      for i = 0 to Array.length hs - 1 do
        (Array.unsafe_get hs i) vm
      done
    end;
    skip := false;
    step vm
  done

let run vm hints end_seg =
  try run_fast vm hints end_seg
  with Relocating -> run_relocating vm hints end_seg ~skip_hints:true
