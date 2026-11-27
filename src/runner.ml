(* Runner mirroring cairo-vm v3.2.0's cairo_run: execution mode and canonical
   (Cairo 0) proof mode.

   Proof mode follows vm/src/vm/runners/cairo_runner.rs: every layout builtin
   gets a runner and a segment (only program builtins are "included"), the
   run starts at __start__ with the stack [exec+2, 0, builtin bases...],
   stops at __end__ plus one step, and end_run pads the trace to a power of
   two until every layout resource check (builtin cells, range-check units,
   memory units, diluted units) passes. finalize_segments fixes builtin
   segment sizes to their allocated sizes and records the public memory. *)

open Vm

let layout_builtins = function
  | "plain" -> Some []
  | "small" | "dex" | "perpetual" -> Some [ Output; Pedersen; Range_check; Ecdsa ]
  | "dex_with_bitwise" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise ]
  | "recursive" -> Some [ Output; Pedersen; Range_check; Bitwise ]
  | "recursive_with_poseidon" | "recursive_large_output" -> Some [ Output; Pedersen; Range_check; Bitwise; Poseidon ]
  | "starknet" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Poseidon ]
  | "starknet_with_keccak" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon ]
  | "all_solidity" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op ]
  | "all_cairo" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "all_cairo_stwo" -> Some [ Output; Pedersen; Range_check; Bitwise; Ec_op; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "stwo_no_ecop" -> Some [ Output; Pedersen; Range_check; Bitwise; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "dynamic" ->
      Some ([ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96 ]
            @ if Layout.with_mod_builtin then [ Add_mod; Mul_mod ] else [])
  | _ -> None

type config = {
  layout : string;
  trace : bool;
  secure_run : bool;
  allow_missing_builtins : bool;
  entrypoint : string;
}

(* Accessed-address bookkeeping for memory-hole counting. cairo-vm marks the
   pc, dst, op0 and op1 cells of every executed instruction and the whole
   program segment. We recover the same set from the trace, together with
   the instruction-offset range-check limits. *)
type accessed = {
  mutable bits : Bytes.t array;
  mutable count : int array;
  mutable cursor : int; (* trace words processed *)
  mutable rc_lo : int; (* rc_lo > rc_hi = no instruction seen *)
  mutable rc_hi : int;
}

type t = {
  vm : vm;
  prog : Program.t;
  end_seg : int; (* execution mode only *)
  hints : (vm -> unit) array array;
  prog_builtins : bkind list;
  scopes : Hintrt.scopes;
  proof : bool;
  layout : Layout.t option; (* proof mode only *)
  end_pc : int; (* proof mode: offset of __end__ in segment 0 *)
  initial_fp : int;
  mutable exec_public : int list; (* reversed offsets of public execution memory *)
  mutable eff_sizes : int array option; (* segment used sizes, fixed at end_run *)
  seg_sizes : (int, int) Hashtbl.t; (* finalized segment sizes *)
  public_offsets : (int, (int * int) list) Hashtbl.t; (* segment -> (offset, page) *)
  acc : accessed;
}

let rec is_subsequence xs ys =
  match (xs, ys) with
  | [], _ -> true
  | _, [] -> false
  | x :: xs', y :: ys' -> if x = y then is_subsequence xs' ys' else is_subsequence xs ys'

let seg_flag_of = function
  | Range_check -> k_rc
  | Range_check96 -> k_rc96
  | Pedersen | Bitwise | Ec_op | Keccak | Poseidon -> k_deduce
  | Ecdsa -> k_ecdsa
  | _ -> k_plain

let compile_hints prog =
  let scopes = Hintrt.new_scopes () in
  Hints_registry.init ();
  let hints = Array.make (Array.length prog.Program.data) [||] in
  List.iter
    (fun (pc, hs) ->
      if pc < Array.length hints then
        hints.(pc) <- Array.of_list (List.map (fun h -> Hints.compile prog scopes h) hs))
    prog.hints;
  (scopes, hints)

let entry_pc (cfg : config) (prog : Program.t) =
  let name = cfg.entrypoint in
  let full = "__main__." ^ name in
  match Hashtbl.find_opt prog.identifiers full with
  | Some { Program.i_pc = Some pc; _ } -> pc
  | _ -> ( match (name, prog.main) with "main", Some pc -> pc | _ -> fail "Entrypoint %s not found" name)

let initialize ?layout_def ?(proof = false) (cfg : config) (prog : Program.t) : t =
  let prog_builtins =
    List.map
      (fun n -> match bkind_of_name n with Some k -> k | None -> fail "Unknown builtin %s" n)
      prog.builtins
  in
  if not (is_subsequence prog_builtins all_builtins) then fail "Disordered builtins";
  let layout_kinds, layout_def =
    if proof then begin
      let l =
        match layout_def with
        | Some l -> l
        | None -> ( match Layout.of_name cfg.layout with Some l -> l | None -> fail "Unsupported layout %s" cfg.layout)
      in
      (Layout.builtin_kinds l, Some l)
    end
    else ((match layout_builtins cfg.layout with Some l -> l | None -> fail "Unsupported layout %s" cfg.layout), None)
  in
  List.iter
    (fun b ->
      if (not (List.mem b layout_kinds)) && not cfg.allow_missing_builtins then
        fail "Program uses builtin %s, which is not present in layout %s" (bname b) cfg.layout)
    prog_builtins;
  (* proof mode always records the trace: memory-hole accounting replays it *)
  let vm = create ~trace:(cfg.trace || proof) in
  let s0 = add_segment vm in
  let s1 = add_segment vm in
  assert (s0 = 0 && s1 = 1);
  (* execution mode: program builtins only; proof mode: every layout builtin *)
  let active = if proof then layout_kinds else List.filter (fun b -> List.mem b prog_builtins) layout_kinds in
  let builtins =
    List.map
      (fun k ->
        let included = List.mem k prog_builtins in
        (match k with
        | (Ecdsa | Add_mod | Mul_mod) when included -> fail "Builtin %s is not supported by this VM" (bname k)
        | _ -> ());
        let seg = add_segment vm in
        let b = { kind = k; base = seg; included; stop_ptr = -1; cache = [||] } in
        vm.seg_builtin.(seg) <- Some b;
        vm.seg_flag.(seg) <- seg_flag_of k;
        b)
      active
  in
  vm.builtins <- builtins;
  (* program image *)
  Array.iteri (fun i z -> write vm 0 i (Felt.of_z z)) prog.data;
  let builtin_stack =
    List.map
      (fun k ->
        match List.find_opt (fun b -> b.kind = k) builtins with
        | Some b -> Felt.reloc b.base 0
        | None -> Felt.zero)
      prog_builtins
  in
  let base =
    {
      vm; prog; end_seg = -1; hints = [||]; prog_builtins; scopes = Hintrt.new_scopes (); proof; layout = layout_def;
      end_pc = -1; initial_fp = 0; exec_public = []; eff_sizes = None; seg_sizes = Hashtbl.create 16;
      public_offsets = Hashtbl.create 16;
      acc = { bits = [||]; count = [||]; cursor = 0; rc_lo = max_int; rc_hi = min_int };
    }
  in
  let base =
    if proof then begin
      ignore (entry_pc cfg prog);
      let start = match prog.start with Some s -> s | None -> fail "Missing __start__ label (NoProgramStart)" in
      let end_pc = match prog.end_ with Some e -> e | None -> fail "Missing __end__ label (NoProgramEnd)" in
      (* canonical proof mode: [exec + 2, 0, builtins...] with fp = ap = exec + 2 *)
      let stack = Felt.reloc 1 2 :: Felt.zero :: builtin_stack in
      List.iteri (fun i v -> write vm 1 i v) stack;
      vm.pc_seg <- 0;
      vm.pc <- start;
      vm.ap <- 2;
      vm.fp <- 2;
      { base with end_pc; initial_fp = 2; exec_public = List.rev (List.init (List.length stack) Fun.id) }
    end
    else begin
      let return_fp = add_segment vm in
      let end_seg = add_segment vm in
      let entry = entry_pc cfg prog in
      let stack = builtin_stack @ [ Felt.reloc return_fp 0; Felt.reloc end_seg 0 ] in
      List.iteri (fun i v -> write vm 1 i v) stack;
      let n = List.length stack in
      vm.pc_seg <- 0;
      vm.pc <- entry;
      vm.ap <- n;
      vm.fp <- n;
      { base with end_seg; initial_fp = n }
    end
  in
  let scopes, hints = compile_hints prog in
  { base with scopes; hints }

(* ---- running ---- *)

let run_hints r =
  let vm = r.vm in
  if vm.pc_seg = 0 && vm.pc < Array.length r.hints then begin
    let hs = r.hints.(vm.pc) in
    for i = 0 to Array.length hs - 1 do
      hs.(i) vm
    done
  end

(* Proof mode stops at a program-segment pc, which run_fast's interface
   (stop at end_seg:0) cannot express; use the generic step. *)
let run_until_pc r seg pc =
  let vm = r.vm in
  while not (vm.pc_seg = seg && vm.pc = pc) do
    run_hints r;
    step vm
  done

let run_for_steps r n =
  for _ = 1 to n do
    run_hints r;
    step r.vm
  done

let run_until_end r =
  if r.proof then begin
    run_until_pc r 0 r.end_pc;
    (* one more step so that __end__ is the last executed instruction *)
    run_for_steps r 1
  end
  else run_fast r.vm r.hints r.end_seg

(* ---- accessed addresses and instruction offset limits, from the trace ---- *)

let mark acc seg off =
  if seg >= 0 && off >= 0 then begin
    if seg >= Array.length acc.bits then begin
      let n = max 16 (2 * (seg + 1)) in
      let nb = Array.make n Bytes.empty and nc = Array.make n 0 in
      Array.blit acc.bits 0 nb 0 (Array.length acc.bits);
      Array.blit acc.count 0 nc 0 (Array.length acc.count);
      acc.bits <- nb;
      acc.count <- nc
    end;
    let b = acc.bits.(seg) in
    let b =
      if off >= Bytes.length b then begin
        let n = ref (max 64 (Bytes.length b)) in
        while !n <= off do
          n := 2 * !n
        done;
        let nb = Bytes.make !n '\000' in
        Bytes.blit b 0 nb 0 (Bytes.length b);
        acc.bits.(seg) <- nb;
        nb
      end
      else b
    in
    if Bytes.unsafe_get b off = '\000' then begin
      Bytes.unsafe_set b off '\001';
      acc.count.(seg) <- acc.count.(seg) + 1
    end
  end

let decoded vm pc_seg pc =
  if pc_seg = 0 && pc < Array.length vm.icache && vm.icache.(pc) <> 0 then vm.icache.(pc) land lnot hint_bit
  else decode_at vm pc_seg pc

(* Trace layout (see Vm.record_trace): a packed word with low bit 1, or a
   relocatable pc code followed by ap and fp. *)
let trace_entry t i =
  let w = sget t i in
  if w land 1 = 1 then (i + 1, 0, w lsr 47, (w lsr 24) land ((1 lsl 23) - 1), (w lsr 1) land ((1 lsl 23) - 1))
  else (i + 3, Felt.rseg w, Felt.roff w, sget t (i + 1), sget t (i + 2))

let update_accessed r =
  let vm = r.vm and acc = r.acc in
  if acc.cursor = 0 then
    for i = 0 to Array.length r.prog.data - 1 do
      mark acc 0 i
    done;
  let t = vm.trace in
  let i = ref acc.cursor in
  while !i < vm.tlen do
    let next, pc_seg, pc, ap, fp = trace_entry t !i in
    i := next;
    let d = decoded vm pc_seg pc in
    let f0 = d land 0xffff and f1 = (d lsr 16) land 0xffff and f2 = (d lsr 32) land 0xffff in
    let lo = min f0 (min f1 f2) and hi = max f0 (max f1 f2) in
    if lo < acc.rc_lo then acc.rc_lo <- lo;
    if hi > acc.rc_hi then acc.rc_hi <- hi;
    let off0 = f0 - 0x8000 and off1 = f1 - 0x8000 and off2 = f2 - 0x8000 in
    let dst_addr = (if d land (1 lsl 48) <> 0 then fp else ap) + off0 in
    let op0_addr = (if d land (1 lsl 49) <> 0 then fp else ap) + off1 in
    mark acc 1 dst_addr;
    mark acc 1 op0_addr;
    (match (d lsr 50) land 3 with
    | 0 ->
        let op0 = read vm 1 op0_addr in
        if Felt.is_reloc op0 then mark acc (Felt.rseg op0) (Felt.roff op0 + off2)
    | 1 -> mark acc pc_seg (pc + 1)
    | 2 -> mark acc 1 (fp + off2)
    | _ -> mark acc 1 (ap + off2));
    mark acc pc_seg pc
  done;
  acc.cursor <- !i

let accessed_count r seg =
  update_accessed r;
  if seg < Array.length r.acc.count then r.acc.count.(seg) else 0

(* ---- end of run ---- *)

let verify_auto_deductions ?(fill_holes=false) vm =
  List.iter
    (fun b ->
      if vm.seg_flag.(b.base) = k_deduce then begin
        let n = used_size vm b.base in
        let width = cells_per_instance b.kind and inputs = n_input_cells b.kind in
        let limit = if fill_holes then ((n + width - 1) / width) * width else n in
        if fill_holes && limit > n then begin
          if limit > slen vm.segs.(b.base) then grow_seg vm b.base (limit - 1);
          vm.hi.(b.base) <- limit
        end;
        for instance = 0 to (limit + width - 1) / width - 1 do
          for off = instance * width + inputs to min limit ((instance + 1) * width) - 1 do
            let v = read vm b.base off in
            let cached = cache_get b off in
            let d = if cached <> 0 then cached else deduce_builtin vm b b.base off in
            if d <> 0 then begin
              if v = 0 then (if fill_holes then write vm b.base off d)
              else if not (Felt.equal d v) then
                fail "Inconsistent auto-deduction for %s builtin at %d:%d: expected %s, got %s" (bname b.kind) b.base off
                  (value_to_string d) (value_to_string v)
            end
          done
        done
      end)
    vm.builtins

(* ---- layout resource accounting (proof mode) ---- *)

exception Insufficient of string

let insufficient fmt = Printf.ksprintf (fun s -> raise (Insufficient s)) fmt

let the_layout r = match r.layout with Some l -> l | None -> fail "layout accounting requires proof mode"

let used_cells r b =
  match r.eff_sizes with
  | Some s -> if b.base < Array.length s then s.(b.base) else fail "Missing segment used sizes"
  | None -> used_size r.vm b.base

let div_ceil a b = (a + b - 1) / b

let used_instances r b =
  match b.kind with
  | Output | Range_check | Range_check96 -> used_cells r b
  | k -> div_ceil (used_cells r b) (cells_per_instance k)

let ratio r b = List.assoc b.kind (the_layout r).builtins

let allocated_instances r b =
  match b.kind with
  | Output -> 0
  | k ->
      let { Layout.num; den } = ratio r b in
      if num = 0 then 0
      else begin
        let step = r.vm.steps in
        let min_step = div_ceil (num * Layout.instances_per_component k) den in
        if step < min_step then insufficient "Number of steps must be at least %d for the %s builtin." min_step (bname k);
        if step * den mod num <> 0 then fail "Error calculating memory units for the %s builtin" (bname k);
        step * den / num
      end

let cells_of b = match b.kind with Output -> 0 | k -> cells_per_instance k

let allocated_memory_units r b = allocated_instances r b * cells_of b

let used_and_allocated r b =
  match b.kind with
  | Output ->
      let u = used_cells r b in
      (u, u)
  | k ->
      let used = used_cells r b in
      let size = allocated_memory_units r b in
      if used > size then begin
        if (ratio r b).num = 0 then
          (* cairo-vm would pad forever: a ratio-0 builtin never gains capacity *)
          fail "Builtin %s has ratio 0 in this layout but uses %d cells" (bname k) used;
        insufficient "The %s builtin used %d cells but the capacity is %d." (bname k) used size
      end;
      (used, size)

let u64_mask = Z.of_string "18446744073709551615"

(* min/max over the 16-bit parts of the range-check segment, in cairo-vm's
   order (each little-endian u64 digit read high part first, first n_parts
   parts). None on an empty segment, a hole or a relocatable value. *)
let builtin_rc_usage vm b =
  let np = Layout.n_parts b.kind in
  let n = used_size vm b.base in
  if np = 0 || n = 0 then None
  else
    try
      let lo = ref max_int and hi = ref min_int in
      let add x =
        if x < !lo then lo := x;
        if x > !hi then hi := x
      in
      for i = 0 to n - 1 do
        let v = read vm b.base i in
        if v = 0 || not (Felt.is_felt v) then raise Exit;
        let taken = ref 0 in
        if Felt.is_small v && Felt.small_val v >= 0 then begin
          let d0 = Felt.small_val v in
          for p = 3 downto 0 do
            if !taken < np then (add ((d0 lsr (16 * p)) land 0xffff); incr taken)
          done;
          if !taken < np then add 0
        end
        else begin
          let z = Felt.to_z v in
          let k = ref 0 in
          while !taken < np do
            let d = Z.logand (Z.shift_right z (64 * !k)) u64_mask in
            for p = 3 downto 0 do
              if !taken < np then begin
                add (Z.to_int (Z.logand (Z.shift_right d (16 * p)) (Z.of_int 0xffff)));
                incr taken
              end
            done;
            incr k
          done
        end
      done;
      Some (!lo, !hi)
    with Exit -> None

let perm_range_check_limits r =
  update_accessed r;
  let acc = r.acc in
  let init = if acc.rc_lo <= acc.rc_hi then Some (acc.rc_lo, acc.rc_hi) else None in
  List.fold_left
    (fun cur b ->
      match builtin_rc_usage r.vm b with
      | None -> cur
      | Some (a, c) -> ( match cur with None -> Some (a, c) | Some (x, y) -> Some (min x a, max y c)))
    init r.vm.builtins

let check_range_check_usage r =
  match perm_range_check_limits r with
  | None -> ()
  | Some (lo, hi) ->
      let used =
        List.fold_left
          (fun s b ->
            match b.kind with
            | Range_check | Range_check96 -> s + (fst (used_and_allocated r b) * Layout.n_parts b.kind)
            | _ -> s)
          0 r.vm.builtins
      in
      let unused = (((the_layout r).rc_units - 3) * r.vm.steps) - used in
      (* a negative difference wraps (usize) in cairo-vm release builds *)
      if unused >= 0 && unused < hi - lo then
        insufficient "There are only %d cells to fill the range checks holes, but potentially %d are required." unused
          (hi - lo)

let is_builtin_seg r seg = List.exists (fun b -> b.base = seg && b.kind <> Output) r.vm.builtins

let segment_size r seg =
  match Hashtbl.find_opt r.seg_sizes seg with
  | Some s -> s
  | None -> (
      match r.eff_sizes with
      | Some s -> if seg < Array.length s then s.(seg) else fail "Missing segment used sizes for segment %d" seg
      | None -> used_size r.vm seg)

let memory_holes r =
  let holes = ref 0 in
  for seg = 0 to r.vm.nsegs - 1 do
    if not (is_builtin_seg r seg) then begin
      let a = accessed_count r seg in
      if a > 0 then begin
        let size = segment_size r seg in
        if a > size then fail "Segment %d has %d accessed addresses but its size is %d" seg a size;
        holes := !holes + (size - a)
      end
    end
  done;
  !holes

let u32 x = x land 0xffffffff

let check_memory_usage r =
  let l = the_layout r in
  let builtin_units = u32 (List.fold_left (fun s b -> s + allocated_memory_units r b) 0 r.vm.builtins) in
  let step = u32 r.vm.steps in
  let total = u32 (l.memory_units_per_step * step) in
  if l.public_memory_fraction = 0 || total mod l.public_memory_fraction <> 0 then
    fail "Memory units %d are not divisible by the public memory fraction %d" total l.public_memory_fraction;
  let public_units = total / l.public_memory_fraction in
  let instr = u32 (4 * step) in
  let unused = u32 (total - u32 (public_units + instr + builtin_units)) in
  let holes = memory_holes r in
  if unused < holes then
    insufficient "There are only %d cells to fill the memory address holes, but %d are required." unused holes

let check_diluted_check_usage r =
  match (the_layout r).diluted with
  | None -> ()
  | Some d ->
      let used =
        List.fold_left
          (fun s b ->
            let u = Layout.used_diluted_units b.kind d.spacing d.n_bits in
            s + (u * allocated_instances r b))
          0 r.vm.builtins
      in
      let step = r.vm.steps in
      let units =
        if not d.fractional then d.units_per_step * step
        else if step mod d.units_per_step <> 0 then
          fail "Diluted units: %d steps are not divisible by %d" step d.units_per_step
        else step / d.units_per_step
      in
      let unused = max 0 (units - used) in
      let bound = 1 lsl d.n_bits in
      if unused < bound then
        insufficient "There are only %d cells to fill the diluted check holes, but potentially %d are required." unused
          bound

let check_used_cells r =
  List.iter (fun b -> ignore (used_and_allocated r b)) r.vm.builtins;
  check_range_check_usage r;
  check_memory_usage r;
  check_diluted_check_usage r

let next_pow2 n =
  let p = ref 1 in
  while !p < n do
    p := 2 * !p
  done;
  !p

let run_until_next_power_of_2 r = run_for_steps r (next_pow2 r.vm.steps - r.vm.steps)

let read_return_values r ~allow_missing =
  let vm = r.vm in
  let pointer = ref vm.ap in
  List.iter
    (fun k ->
      match List.find_opt (fun b -> b.kind = k) vm.builtins with
      | Some b ->
          let addr = !pointer - 1 in
          if addr < 0 then fail "No stop pointer for builtin %s" (bname k);
          let sp = read vm 1 addr in
          if not (Felt.is_reloc sp) then fail "Stop pointer of %s is not a relocatable" (bname k);
          if Felt.rseg sp <> b.base then fail "Invalid stop pointer index for %s" (bname k);
          let cpi = cells_per_instance k in
          let used = used_size vm b.base in
          let instances = (used + cpi - 1) / cpi in
          if Felt.roff sp <> instances * cpi then
            fail "Invalid stop pointer for %s. Expected: %d:%d, found: %d:%d" (bname k) b.base (instances * cpi) b.base
              (Felt.roff sp);
          b.stop_ptr <- Felt.roff sp;
          pointer := addr
      | None ->
          if not allow_missing then fail "Missing builtin %s" (bname k);
          pointer := max 0 (!pointer - 1);
          if r.proof then begin
            let v = read vm 1 !pointer in
            if v = 0 || not (Felt.is_felt v) then fail "Expected integer at address 1:%d" !pointer;
            if not (Felt.equal v Felt.zero) then fail "Missing builtin %s: stop pointer is not zero" (bname k)
          end)
    (List.rev r.prog_builtins);
  if r.proof then
    for o = !pointer to vm.ap - 1 do
      r.exec_public <- o :: r.exec_public
    done

let finalize_segments r =
  let size = Array.length r.prog.data in
  Hashtbl.replace r.seg_sizes 0 size;
  Hashtbl.replace r.public_offsets 0 (List.init size (fun i -> (i, 0)));
  Hashtbl.replace r.public_offsets 1 (List.rev_map (fun o -> (o, 0)) r.exec_public);
  List.iter
    (fun b ->
      let _, size = try used_and_allocated r b with Insufficient m -> fail "Failed to finalize segments: %s" m in
      Hashtbl.replace r.seg_sizes b.base size;
      Hashtbl.replace r.public_offsets b.base
        (if b.kind = Output then List.init (used_cells r b) (fun i -> (i, 0)) else []))
    r.vm.builtins

let verify_secure_runner r =
  let vm = r.vm in
  List.iter
    (fun b ->
      let n = used_size vm b.base in
      (* builtins without a stop pointer (proof-mode extras) are skipped *)
      if b.stop_ptr >= 0 && n >= b.stop_ptr + 1 then fail "Out of bounds access to builtin segment %s" (bname b.kind))
    vm.builtins;
  if used_size vm 0 > Array.length r.prog.data then fail "Out of bounds access to program segment";
  (* builtin security checks: inputs of every instance must be present *)
  List.iter
    (fun b ->
      match b.kind with
      | Output -> ()
      | k ->
          let n = used_size vm b.base in
          if n > 0 then begin
            let cpi = cells_per_instance k and nin = n_input_cells k in
            let filled = ref 0 in
            for i = 0 to n - 1 do
              if read vm b.base i <> 0 then incr filled
            done;
            let ninst = ((n - 1) / cpi) + 1 in
            if ninst > !filled / nin then fail "Missing memory cells for builtin %s" (bname k);
            for i = 0 to ninst - 1 do
              for j = 0 to nin - 1 do
                if read vm b.base ((cpi * i) + j) = 0 then
                  fail "Missing memory cells for builtin %s at offset %d" (bname k) ((cpi * i) + j)
              done;
              for j = nin to cpi - 1 do
                let off = (cpi * i) + j in
                if read vm b.base off = 0 && vm.seg_flag.(b.base) = k_deduce then
                  ignore (deduce_builtin vm b b.base off)
              done
            done
          end)
    vm.builtins;
  if r.proof then begin
    (* canonical proof mode: [initial_fp - 2] must be the final fp *)
    let v = read vm 1 (r.initial_fp - 2) in
    if v = 0 then fail "Missing return fp at 1:%d" (r.initial_fp - 2);
    if Felt.is_reloc v then begin
      if v <> Felt.reloc 1 vm.fp then
        fail "Return fp %d:%d does not match final fp 1:%d" (Felt.rseg v) (Felt.roff v) vm.fp
    end
    else if not (Felt.equal v (Felt.of_int vm.fp)) then
      fail "Return fp %s does not match final fp 1:%d" (value_to_string v) vm.fp
  end

let end_run ?(fill_holes=false) r ~secure ~allow_missing =
  if r.proof then begin
    verify_auto_deductions ~fill_holes r.vm;
    if not (Hintrt.only_main_scope r.scopes) then fail "Every enter_scope() requires a corresponding exit_scope()";
    r.eff_sizes <- Some (Array.init r.vm.nsegs (used_size r.vm));
    run_until_next_power_of_2 r;
    let rec pad () =
      match check_used_cells r with
      | () -> ()
      | exception Insufficient _ ->
          run_for_steps r 1;
          run_until_next_power_of_2 r;
          pad ()
    in
    pad ();
    read_return_values r ~allow_missing;
    finalize_segments r;
    if secure then verify_secure_runner r
  end
  else begin
    if not (Hintrt.only_main_scope r.scopes) then fail "Every enter_scope() requires a corresponding exit_scope()";
    verify_auto_deductions ~fill_holes r.vm;
    read_return_values r ~allow_missing;
    if secure then verify_secure_runner r
  end

(* ---- relocation & outputs ---- *)

let relocation_table r =
  let vm = r.vm in
  let t = Array.make (vm.nsegs + 1) 1 in
  for s = 0 to vm.nsegs - 1 do
    let size = if r.proof then segment_size r s else used_size vm s in
    t.(s + 1) <- t.(s) + size
  done;
  t

external c_write_trace : string -> seg -> int -> int array -> unit = "cvm_write_trace"

external c_write_memory : string -> seg array -> int array -> int array -> int -> bytes -> unit
  = "cvm_write_memory_byte" "cvm_write_memory"

let write_trace r path =
  let vm = r.vm in
  c_write_trace path vm.trace vm.tlen (relocation_table r)

let write_memory r path =
  let vm = r.vm in
  let sizes = Array.init vm.nsegs (used_size vm) in
  c_write_memory path vm.segs sizes (relocation_table r) vm.nsegs !Felt.pool

(* first and last trace entries as (pc_seg, pc, ap, fp) *)
let trace_bounds r =
  let vm = r.vm in
  if vm.tlen = 0 then None
  else begin
    let i = ref 0 and first = ref None and last = ref (0, 0, 0, 0) in
    while !i < vm.tlen do
      let next, s, pc, ap, fp = trace_entry vm.trace !i in
      if !first = None then first := Some (s, pc, ap, fp);
      last := (s, pc, ap, fp);
      i := next
    done;
    Option.map (fun f -> (f, !last)) !first
  end

let output_segment r =
  List.find_opt (fun b -> b.kind = Output) r.vm.builtins

let output_line vm seg i =
  let v = read vm seg i in
  if v = 0 then "<missing>"
  else if Felt.is_small v then string_of_int (Felt.small_val v)
  else if Felt.is_reloc v then Printf.sprintf "%d:%d" (Felt.rseg v) (Felt.roff v)
  else Z.to_string (Felt.to_signed_z v)

let iter_output_lines r emit =
  match output_segment r with
  | None -> ()
  | Some b ->
      for i = 0 to used_size r.vm b.base - 1 do
        emit (output_line r.vm b.base i)
      done

let output_lines r =
  match output_segment r with
  | None -> []
  | Some b -> List.init (used_size r.vm b.base) (output_line r.vm b.base)
