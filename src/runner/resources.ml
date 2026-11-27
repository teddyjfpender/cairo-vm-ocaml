open Errors
open Segment
open Builtin
open Instruction
open Vm
open Deduce
open Cpu
open Runner

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

(* cached words are Stone instructions whose bit 61 may be Cpu.run's hint
   flag; extension words are never cached and decode with their extension *)
let decoded vm pc_seg pc =
  if pc_seg = 0 && pc < Array.length vm.icache && vm.icache.(pc) <> 0 then vm.icache.(pc) land lnot ext_mask
  else decode_at vm pc_seg pc

(* Trace layout (see Cpu.record_trace): a packed word with low bit 1, or a
   relocatable pc code followed by ap and fp. *)
let trace_entry t i =
  let w = raw_get t i in
  if w land 1 = 1 then (i + 1, 0, w lsr 47, (w lsr 24) land ((1 lsl 23) - 1), (w lsr 1) land ((1 lsl 23) - 1))
  else
    let pc = Felt.unsafe_of_int w in
    (i + 3, Felt.rseg pc, Felt.roff pc, raw_get t (i + 1), raw_get t (i + 2))

external trace_access :
  seg -> int -> int array -> seg -> Bytes.t array -> int array -> int array -> int array -> unit
  = "cvm_trace_access_byte" "cvm_trace_access" [@@noalloc]

let update_accessed r =
  let vm = r.vm and acc = r.acc in
  if acc.cursor = 0 then
    for i = 0 to Array.length r.prog.data - 1 do
      mark acc 0 i
    done;
  let t = vm.trace in
  let state = [|acc.cursor; acc.rc_lo; acc.rc_hi; -1; 0; Array.length r.prog.data|] in
  let page = ref [||] in
  while state.(0) < vm.tlen do
    trace_access t vm.tlen vm.icache vm.segs.(1) acc.bits acc.count state !page;
    if state.(0) < vm.tlen then begin
      let next, pc_seg, pc, ap, fp = trace_entry t state.(0) in
      state.(0) <- next;
      let d =
        if pc_seg <= 0 then decoded vm pc_seg pc else begin
          let base = pc land lnot 1023 in
          if state.(3) <> pc_seg || state.(4) <> base then begin
            page := Option.value (Hashtbl.find_opt vm.code_pages (pc_seg, base)) ~default:[||];
            state.(3) <- pc_seg;
            state.(4) <- base
          end;
          let index = pc-base in
          if index < Array.length !page && !page.(index) <> 0 then !page.(index) land lnot ext_mask
          else decode_at vm pc_seg pc
        end in
      let f0 = d land 0xffff and f1 = (d lsr 16) land 0xffff and f2 = (d lsr 32) land 0xffff in
      let lo = min f0 (min f1 f2) and hi = max f0 (max f1 f2) in
      if lo < state.(1) then state.(1) <- lo;
      if hi > state.(2) then state.(2) <- hi;
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
      mark acc pc_seg pc;
      (* Blake2s / BlakeFinalize write their 8 output words as accessed *)
      let ext = (d lsr ext_shift) land 3 in
      if ext = 1 || ext = 2 then begin
        let out = read vm 1 ap in
        if Felt.is_reloc out then
          for k = 0 to 7 do
            mark acc (Felt.rseg out) (Felt.roff out + k)
          done
      end
    end
  done;
  acc.rc_lo <- state.(1);
  acc.rc_hi <- state.(2);
  acc.cursor <- state.(0);
  List.iter (fun (sg, o) -> mark acc sg o) !Builtins_ext.accessed_log;
  Builtins_ext.accessed_log := []

let range_accessed r ptr length =
  update_accessed r;
  let seg = Felt.rseg ptr and off = Felt.roff ptr in
  if seg < 0 || seg >= Array.length r.acc.bits then false else
  let bits = r.acc.bits.(seg) in
  off < Bytes.length bits && (match Bytes.index_from_opt bits off '\001' with
    | Some i -> i - off < length | None -> false)

let accessed_count r seg =
  update_accessed r;
  if seg < Array.length r.acc.count then r.acc.count.(seg) else 0

(* ---- end of run ---- *)

external verified_bitwise : Felt.pool -> seg -> int -> bool = "cvm_verify_bitwise" [@@noalloc]

external verified_pedersen : Felt.pool -> seg -> int -> Felt.t array -> bool = "cvm_verify_pedersen" [@@noalloc]

(* PIE memory is write-once. A verified, fully populated input triple
   therefore remains valid through execution. Snapshot the segment words
   so the worker never races stack writes, segment growth, or deduction.
   Committed big felt slots are immutable for the lifetime of the run. *)
external start_pedersen : Felt.pool -> Segment.seg -> nativeint = "cvm_start_pedersen"
external join_pedersen : nativeint -> Segment.seg -> bool = "cvm_join_pedersen" [@@noalloc]

let with_preverified_pedersen vm execute =
  match List.find_opt (fun b -> b.kind = Pedersen) vm.builtins with
  | Some b when used_size vm b.base >= 3 * 2048 ->
      let n = used_size vm b.base in
      let snapshot = Segment.snapshot vm.segs.(b.base) n in
      let worker = start_pedersen Felt.pool snapshot in
      let result = try execute () with ex -> ignore (join_pedersen worker snapshot); raise ex in
      if join_pedersen worker snapshot then begin
        for i = 0 to n / 3 - 1 do
          let off = 3 * i in
          let a = sget snapshot off and c = sget snapshot (off + 1) and out = sget snapshot (off + 2) in
          if Felt.is_felt a && Felt.is_felt c && Felt.is_felt out then cache_set b (off + 2) out
        done
      end;
      result
  | _ -> execute ()

let verify_auto_deductions ?(fill_holes=false) vm =
  List.iter
    (fun b ->
      if is_deducing vm.seg_flag.(b.base) &&
         (fill_holes || not (match b.kind with
          | Bitwise -> verified_bitwise Felt.pool vm.segs.(b.base) (used_size vm b.base)
          | Pedersen -> verified_pedersen Felt.pool vm.segs.(b.base) (used_size vm b.base) b.cache
          | _ -> false)) then begin
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
            let d = if cached <> Felt.empty then cached else deduce_builtin vm b b.base off in
            if d <> Felt.empty then begin
              if v = Felt.empty then (if fill_holes then write vm b.base off d)
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
        if v = Felt.empty || not (Felt.is_felt v) then raise Exit;
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
      let a =
        (* only proof mode finalizes the zero segment; a run from a PIE sizes it without finalizing *)
        if seg = r.zero_seg && not (r.proof && Hashtbl.mem r.seg_sizes seg) then r.zero_size else accessed_count r seg
      in
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
