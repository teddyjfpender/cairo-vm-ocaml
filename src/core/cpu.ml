open Felt
open Errors
open Segment
open Builtin
open Instruction
open Vm
open Deduce

let decode_at vm seg off =
  if off < 0 then fail "Negative program counter %d:%d" seg off;
  let v = get vm seg off in
  if v = Felt.empty then fail "Instruction at %d:%d is not assigned (UnknownMemoryCell)" seg off;
  if not (is_felt v) then fail "Instruction at %d:%d is a relocatable value" seg off;
  let z = Felt.to_z v in
  try decode_word z
  with Generic_instruction -> fail "Unsupported generic instruction at pc %d:%d: 0x%s" seg off (Z.format "%x" z)

(* Dynamic contract bytecode can occupy a small region far into a segment.
   Allocate decoded words only in pages actually executed. *)
let contract_page vm =
  let base = vm.pc land lnot 1023 in
  if vm.code_seg <> vm.pc_seg || vm.code_base <> base then begin
    let key = vm.pc_seg, base in
    let page = match Hashtbl.find_opt vm.code_pages key with
      | Some page -> page
      | None -> let page = Array.make 1024 0 in Hashtbl.add vm.code_pages key page; page
    in
    vm.code_seg <- vm.pc_seg; vm.code_base <- base; vm.code_page <- page
  end;
  vm.code_page

let[@inline never] fetch_slow vm =
  if vm.pc_seg = 0 then begin
    let d = decode_at vm 0 vm.pc in
    if vm.pc >= Array.length vm.icache then begin
      let n = ref (max 64 (Array.length vm.icache)) in
      while !n <= vm.pc do
        n := 2 * !n
      done;
      let na = Array.make !n 0 in
      Array.blit vm.icache 0 na 0 (Array.length vm.icache);
      vm.icache <- na
    end;
    if d land ext_mask = 0 then vm.icache.(vm.pc) <- d;
    d
  end
  else if vm.pc_seg < 0 then decode_at vm vm.pc_seg vm.pc
  else begin
    let page = contract_page vm and index = vm.pc land 1023 in
    let cached = page.(index) in
    if cached <> 0 then cached land lnot (1 lsl 61) else
      let d = decode_at vm vm.pc_seg vm.pc in
      if d land ext_mask = 0 then
        page.(index) <- (if Hashtbl.mem vm.runtime_hints (vm.pc_seg, vm.pc) then d lor (1 lsl 61) else d);
      d
  end

(* ---------------- step ---------------- *)

let[@inline never] trace_grow vm =
  vm.trace <- seg_grow vm.trace (2 * slen vm.trace)

(* Main-program entries end in 1, compact segment-relative entries in 00,
   and a full three-word entry begins with a relocatable PC ending in 10. *)
let[@inline] record_trace vm pc_seg pc ap fp =
  let i = vm.tlen in
  if i + 3 > slen vm.trace then trace_grow vm;
  let t = vm.trace in
  vm.last_trace <- i;
  if pc_seg = 0 && pc lsr 16 = 0 && (ap lor fp) lsr 23 = 0 then begin
    raw_set t i ((pc lsl 47) lor (ap lsl 24) lor (fp lsl 1) lor 1);
    vm.tlen <- i + 1
  end else if pc_seg lsr 10 = 0 && pc lsr 18 = 0 && ap lsr 24 = 0 && (ap - fp) lsr 9 = 0 then begin
    raw_set t i ((pc_seg lsl 53) lor (pc lsl 35) lor (ap lsl 11) lor ((ap-fp) lsl 2));
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
  if Array.length vm.watched <> 0 then begin
    mark_watched vm pc_seg pc;
    mark_watched vm op1_seg op1_off
  end;
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
   run's hint flag); extension bits are only meaningful on a fresh
   decode, since extension words are never cached. *)
let[@inline never] step_uncached vm =
  let d = fetch_slow vm in
  if d land ext_mask <> 0 then !ext_step vm d else step_instr vm d

let[@inline] step vm =
  if vm.pc_seg = 0 && vm.pc >= 0 && vm.pc < Array.length vm.icache then begin
    let d = Array.unsafe_get vm.icache vm.pc in
    if d <> 0 then step_instr vm d else step_uncached vm
  end
  else step_uncached vm

(* ---------------- interpreter loop ----------------

   Each iteration runs the hints of the current pc, then the native batch
   kernel, which executes that instruction and its successors until a hint
   pc or an instruction it declines.  A declined instruction takes the
   generic [step] above, which implements the full deduction semantics.
   Program counters carrying hints are flagged in the decoded cache, so the
   kernel pays no lookup for hint detection.  The kernel also stops before
   an uncached pc, so a program-segment stop pc only needs a flag while
   cached.  The last steps of a bounded run, fewer than one batch, are
   generic, which keeps the kernel's loop free of caller limits.  Instructions reading a temporary pointer fall back to the generic path
   so that memory reads observe the current relocation rules. *)

let hint_bit = 1 lsl 61
let generic_steps = ref 0
let hint_steps = ref 0

(* The kernel executes a flagged first instruction: its hints already ran. *)
external cpu_batch : int array -> int array -> seg array -> flag array -> int array ->
  seg -> pool -> int -> bool -> Felt.t array -> int = "cvm_cpu_batch_byte" "cvm_cpu_batch" [@@noalloc]

external cpu_batch_watched : int array -> int array -> seg array -> flag array -> int array ->
  seg -> pool -> int -> Bytes.t array -> Felt.t array -> int
  = "cvm_cpu_batch_watched_byte" "cvm_cpu_batch_watched" [@@noalloc]

external cpu_batch_poseidon : int array -> int array -> seg array -> flag array -> int array ->
  seg -> pool -> int -> Bytes.t array -> Felt.t array -> Felt.t array -> int
  = "cvm_cpu_batch_poseidon_byte" "cvm_cpu_batch_poseidon" [@@noalloc]

let register_runtime_hints vm ~segment ~pc handlers =
  if segment <= 0 || not (seg_ok vm segment) || pc < 0 then fail "Invalid runtime hint location";
  Hashtbl.replace vm.runtime_hints (segment, pc) handlers;
  match Hashtbl.find_opt vm.code_pages (segment, pc land lnot 1023) with
  | Some page when page.(pc land 1023) <> 0 ->
      let i = pc land 1023 in page.(i) <- page.(i) lor hint_bit
  | _ -> ()

let batch_max = 8192 (* cvm_cpu_batch's steps per call *)

let run ?(stop = (0, -1)) ?(steps = max_int) vm (hints : (vm -> unit) array array) =
  let stop_seg, stop_pc = stop in
  let cached = if stop_seg = 0 && 0 <= stop_pc && stop_pc < Array.length vm.icache then vm.icache.(stop_pc) else 0 in
  if cached <> 0 then vm.icache.(stop_pc) <- cached lor hint_bit;
  let nh = Array.length hints in
  let pedersen = List.find_opt (fun b -> b.kind = Pedersen) vm.builtins in
  let poseidon = if vm.trace_on then None else List.find_opt (fun b -> b.kind = Poseidon) vm.builtins in
  let registers = Array.make 13 0 in
  let first = vm.steps in
  while not (vm.pc_seg = stop_seg && vm.pc = stop_pc) && vm.steps - first < steps do
    let pc = vm.pc in
    let hinted = vm.pc_seg = 0 && pc >= 0 && pc < nh && Array.length (Array.unsafe_get hints pc) <> 0 in
    if hinted then begin
      incr hint_steps;
      Array.iter (fun h -> h vm) (Array.unsafe_get hints pc)
    end;
    if vm.pc_seg > 0 && Hashtbl.length vm.runtime_hints <> 0 then begin
      match Hashtbl.find_opt vm.runtime_hints (vm.pc_seg, pc) with
      | None -> ()
      | Some handlers -> incr hint_steps; Array.iter (fun run -> run vm) handlers
    end;
    let count =
      if vm.pc_seg < 0 || (vm.pc_seg <> 0 && vm.pc_seg = stop_seg) || steps - (vm.steps - first) < batch_max then 0
      else begin
        registers.(0) <- pc; registers.(1) <- vm.ap; registers.(2) <- vm.fp;
        registers.(3) <- vm.hi.(1); registers.(4) <- vm.tlen; registers.(5) <- !pool_n;
        let cache = if vm.pc_seg = 0 then vm.icache else contract_page vm in
        registers.(10) <- vm.pc_seg;
        registers.(11) <- if vm.pc_seg = 0 then 0 else vm.code_base;
        let ped_cache = match pedersen with Some b -> b.cache | None -> [||] in
        let count =
          match poseidon with
          | Some b -> cpu_batch_poseidon registers cache vm.segs vm.seg_flag vm.hi vm.trace pool
                        vm.nsegs vm.watched ped_cache b.cache
          | None when Array.length vm.watched = 0 ->
            cpu_batch registers cache vm.segs vm.seg_flag vm.hi vm.trace pool vm.nsegs vm.trace_on ped_cache
          | None ->
            cpu_batch_watched registers cache vm.segs vm.seg_flag vm.hi vm.trace pool vm.nsegs vm.watched ped_cache in
        vm.pc <- registers.(0); vm.ap <- registers.(1); vm.fp <- registers.(2);
        vm.hi.(1) <- registers.(3); vm.tlen <- registers.(4); pool_n := registers.(5);
        if count > 0 && vm.trace_on then vm.last_trace <- registers.(9);
        vm.steps <- vm.steps + count;
        count
      end
    in
    if count = 0 then begin
      incr generic_steps;
      step vm;
      if hinted && pc < Array.length vm.icache && vm.icache.(pc) <> 0 then
        vm.icache.(pc) <- vm.icache.(pc) lor hint_bit
    end
  done;
  if cached <> 0 then vm.icache.(stop_pc) <- cached
