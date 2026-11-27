open Felt
open Errors
open Segment
open Builtin

type vm = {
  mutable segs : seg array;
  mutable nsegs : int;
  mutable seg_flag : flag array;
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
  runtime_hints : ((int * int), (vm -> unit) array) Hashtbl.t;
  code_pages : ((int * int), int array) Hashtbl.t;
  mutable code_seg : int;
  mutable code_base : int;
  mutable code_page : int array;
  trace_on : bool;
  mutable trace : seg; (* tagged packed entries or full pc, ap, fp triples *)
  mutable tlen : int;
  mutable last_trace : int;  (* starting word of the last trace entry *)
  mutable builtins : builtin list;
  (* Temporary segments (negative indices, -1 is tseg.(0)) and relocation
     rules keyed by temporary index, as in cairo-vm's Memory.temp_data and
     relocation_rules. [relocating] is set once a rule exists: memory reads
     then translate temporary relocatables, so [Cpu.run] stops using the
     native kernel. *)
  mutable tsegs : seg array;
  mutable thi : int array;
  mutable ntsegs : int;
  mutable rules : (int * Felt.t) list; (* temp index -> destination relocatable *)
  mutable relocating : bool;
  mutable had_temp : bool;
}

let create ~trace =
  {
    segs = Array.make 16 empty_seg;
    nsegs = 0;
    seg_flag = Array.make 16 k_plain;
    hi = Array.make 16 0;
    seg_builtin = Array.make 16 None;
    pc_seg = 0;
    pc = 0;
    ap = 0;
    fp = 0;
    steps = 0;
    icache = [||];
    runtime_hints = Hashtbl.create 8;
    code_pages = Hashtbl.create 8;
    code_seg = -1; code_base = 0; code_page = [||];
    trace_on = trace;
    (* lazily committed; the two extra words are record_trace's headroom, so
       a power-of-two run of packed entries (a padded proof run) fits without
       doubling at every size *)
    trace = (if trace then seg_make ((1 lsl 26) + 2) else empty_seg);
    tlen = 0;
    last_trace = 0;
    builtins = [];
    tsegs = [||];
    thi = [||];
    ntsegs = 0;
    rules = [];
    relocating = false;
    had_temp = false;
  }

let add_segment vm =
  let n = vm.nsegs in
  if n >= Array.length vm.segs then begin
    let grow a d = Array.append a (Array.make (Array.length a) d) in
    vm.segs <- grow vm.segs empty_seg;
    vm.seg_flag <- grow vm.seg_flag k_plain;
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
  if off < slen a then sget a off else Felt.empty

(* ---- temporary segments (cairo-vm MemorySegmentManager.add_temp_segment) ---- *)

let add_temp_segment vm =
  let n = vm.ntsegs in
  if n >= Array.length vm.tsegs then begin
    let cap = max 4 (2 * n) in
    let grow a d = Array.append a (Array.make (cap - Array.length a) d) in
    vm.tsegs <- grow vm.tsegs empty_seg;
    vm.thi <- grow vm.thi 0
  end;
  vm.tsegs.(n) <- seg_make 16;
  vm.thi.(n) <- 0;
  vm.ntsegs <- n + 1;
  vm.had_temp <- true;
  -(n + 1)

let[@inline] temp_index seg = -(seg + 1)

let temp_ok vm seg = seg < 0 && temp_index seg < vm.ntsegs

let[@inline never] temp_read vm seg off =
  if not (temp_ok vm seg) then fail "Unknown memory segment %d" seg;
  let a = vm.tsegs.(temp_index seg) in
  if off >= 0 && off < slen a then sget a off else Felt.empty

(* Memory.relocate_value: one application of the current rules *)
let[@inline never] relocate_temp_value vm v =
  if is_reloc v && rseg v < 0 then
    match List.assoc_opt (temp_index (rseg v)) vm.rules with
    | Some dst ->
        let o = roff dst + roff v in
        if o > off_mask then fail "Offset exceeds range when relocating %d:%d" (rseg v) (roff v);
        reloc (rseg dst) o
    | None -> v
  else v

let get vm seg off =
  let v =
    if seg < 0 then temp_read vm seg off
    else begin
      if not (seg_ok vm seg) then fail "Unknown memory segment %d" seg;
      if off < 0 then Felt.empty else read vm seg off
    end
  in
  if vm.relocating then relocate_temp_value vm v else v

let[@inline never] grow_seg vm seg off =
  let a = vm.segs.(seg) in
  let n = ref (max 16 (slen a)) in
  while !n <= off do
    n := 2 * !n
  done;
  vm.segs.(seg) <- seg_grow a !n

let value_to_string v =
  if v = Felt.empty then "<empty>"
  else if is_reloc v then Printf.sprintf "%d:%d" (rseg v) (roff v)
  else Felt.to_string v

(* Hooks for logic that lives in later modules (which depend on this one).
   [ecdsa_validate vm seg off] is the signature builtin's validation rule for
   a newly written cell; [ext_step vm d] executes one instruction carrying an
   opcode extension (Blake, BlakeFinalize, QM31Operation).  Both fail
   explicitly until installed. *)
let ecdsa_validate : (vm -> int -> int -> unit) ref =
  ref (fun _ seg off -> fail "ecdsa builtin is not supported by this VM (write at %d:%d)" seg off)

let ext_step : (vm -> int -> unit) ref =
  ref (fun _ d -> fail "Unsupported opcode extension %d" ((d lsr 61) land 3))

let[@inline never] validate vm seg off v =
  let f = vm.seg_flag.(seg) in
  if f = k_rc || f = k_rc96 then begin
    if not (is_felt v) then fail "Range-check builtin: found non-int value at %d:%d" seg off;
    let bound = if f = k_rc then 128 else 96 in
    if not (is_small v && small_val v >= 0) && Felt.bits v > bound then
      fail "Range-check builtin: value %s at %d:%d is out of range [0, 2^%d)" (Felt.to_string v) seg off bound
  end
  else if f = k_ecdsa then !ecdsa_validate vm seg off

let[@inline] write vm seg off v =
  if off < 0 then fail "Negative memory offset %d:%d" seg off;
  let a = Array.unsafe_get vm.segs seg in
  if off >= slen a then grow_seg vm seg off;
  let a = Array.unsafe_get vm.segs seg in
  let cur = sget a off in
  if cur = Felt.empty then begin
    sset a off v;
    if off >= Array.unsafe_get vm.hi seg then Array.unsafe_set vm.hi seg (off + 1);
    if Array.unsafe_get vm.seg_flag seg <> k_plain then validate vm seg off v
  end
  else if not (Felt.equal cur v) then
    fail "Inconsistent memory assignment at address %d:%d. %s != %s" seg off (value_to_string cur)
      (value_to_string v)

let[@inline never] temp_write vm seg off v =
  if not (temp_ok vm seg) then fail "Unknown memory segment %d" seg;
  if off < 0 then fail "Negative memory offset %d:%d" seg off;
  let k = temp_index seg in
  let a = vm.tsegs.(k) in
  if off >= slen a then begin
    let n = ref (max 16 (slen a)) in
    while !n <= off do n := 2 * !n done;
    vm.tsegs.(k) <- seg_grow a !n
  end;
  let a = vm.tsegs.(k) in
  let cur = sget a off in
  if cur = Felt.empty then begin
    sset a off v;
    if off >= vm.thi.(k) then vm.thi.(k) <- off + 1
  end
  else if not (Felt.equal cur v) then
    fail "Inconsistent memory assignment at address %d:%d. %s != %s" seg off (value_to_string cur)
      (value_to_string v)

let write_checked vm seg off v =
  if seg < 0 then temp_write vm seg off v
  else begin
    if not (seg_ok vm seg) then fail "Unknown memory segment %d" seg;
    write vm seg off v
  end

(* Memory.add_relocation_rule (without extensive_hints) *)
let add_relocation_rule vm src dst =
  if not (is_reloc src) then fail "add_relocation_rule: src_ptr is not a relocatable";
  if not (is_reloc dst) then fail "add_relocation_rule: dest_ptr is not a relocatable";
  if rseg src >= 0 then fail "Address %d is not in a temporary segment" (rseg src);
  if roff src <> 0 then fail "Non-zero offset %d in relocation source" (roff src);
  let k = temp_index (rseg src) in
  if List.mem_assoc k vm.rules then fail "Duplicated relocation rule for segment %d" (rseg src);
  vm.rules <- (k, dst) :: vm.rules;
  vm.relocating <- true

(* Memory.relocate_memory, run at the start of end_run: flatten rule chains,
   rewrite temporary relocatables in all memory, then move each relocated
   temporary segment into real memory (descending index order, holes skip
   addresses), with ordinary write-once and builtin validation. *)
let relocate_temp_memory vm =
  if vm.rules <> [] && vm.ntsegs > 0 then begin
    let max_hops = List.length vm.rules + 1 in
    let flat =
      List.map
        (fun (k, dst) ->
          let rec go dst hops =
            if rseg dst >= 0 then dst
            else begin
              let next =
                match List.assoc_opt (temp_index (rseg dst)) vm.rules with
                | Some n -> n
                | None -> fail "Unmapped temporary segment %d" (rseg dst)
              in
              let o = roff next + roff dst in
              if o > off_mask then fail "Offset exceeds range in relocation rule";
              if hops + 1 > max_hops then fail "Relocation rule cycle";
              go (reloc (rseg next) o) (hops + 1)
            end
          in
          (k, go dst 0))
        vm.rules
    in
    let relocate v =
      if is_reloc v && rseg v < 0 then
        match List.assoc_opt (temp_index (rseg v)) flat with
        | Some dst ->
            let o = roff dst + roff v in
            if o > off_mask then fail "Offset exceeds range when relocating memory";
            reloc (rseg dst) o
        | None -> v
      else v
    in
    let rewrite a n =
      for i = 0 to n - 1 do
        let v = sget a i in
        if is_reloc v && rseg v < 0 then sset a i (relocate v)
      done
    in
    for s = 0 to vm.nsegs - 1 do rewrite vm.segs.(s) (min vm.hi.(s) (slen vm.segs.(s))) done;
    for k = 0 to vm.ntsegs - 1 do rewrite vm.tsegs.(k) vm.thi.(k) done;
    let keep = ref [] in
    for k = vm.ntsegs - 1 downto 0 do
      match List.assoc_opt k flat with
      | Some dst ->
          let a = vm.tsegs.(k) in
          for i = 0 to vm.thi.(k) - 1 do
            let v = sget a i in
            if v <> Felt.empty then begin
              let o = roff dst + i in
              if o > off_mask then fail "Offset exceeds range when relocating memory";
              write_checked vm (rseg dst) o v
            end
          done
      | None -> keep := (vm.tsegs.(k), vm.thi.(k)) :: !keep
    done;
    let kept = Array.of_list !keep in
    vm.tsegs <- Array.map fst kept;
    vm.thi <- Array.map snd kept;
    vm.ntsegs <- Array.length kept;
    vm.rules <- [];
    vm.relocating <- false
  end

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
