open Felt
open Errors
open Segment
open Builtin

type 'a hint_page = 'a array array array

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
  mutable selection : selection option;
  mutable squash : squash option;
  mutable selection_remaining : int;
  (* trace *)
  runtime_hints : ((int * int), (vm -> unit) hint_page) Hashtbl.t;
  mutable page_hints : (vm -> unit) hint_page;
  code_pages : ((int * int), int array) Hashtbl.t;
  mutable code_seg : int;
  mutable code_base : int;
  mutable code_page : int array;
  mutable watched : Bytes.t array;
  mutable allow_legacy_instructions : bool;
  trace_on : bool;
  mutable trace : seg; (* tagged packed entries or full pc, ap, fp triples *)
  mutable tlen : int;
  mutable last_trace : int;  (* starting word of the last trace entry *)
  signatures : (Felt.t, Z.t * Z.t) Hashtbl.t;
  mutable builtins : builtin list;
  (* Temporary segments (negative indices, -1 is tseg.(0)) and relocation
     rules keyed by temporary index, as in cairo-vm's Memory.temp_data and
     relocation_rules. [relocating] is set once a rule exists: memory reads
     then translate temporary relocatables. *)
  mutable tsegs : seg array;
  mutable thi : int array;
  mutable ntsegs : int;
  mutable rules : Felt.t array; (* temp index -> destination relocatable *)
  mutable relocating : bool;
  mutable had_temp : bool;
}

and squash = {
  begin_row : vm -> unit;
  run_rows : vm -> (vm -> unit) -> int array -> int;
}

and selection = {
  action : vm -> unit;
  publish : int -> unit;
}

(* A supervised job has a hard virtual-memory budget on Linux. Grow its
   execution segment and trace on demand instead of reserving gigabytes. *)
let bounded_host = Option.is_some (Sys.getenv_opt "OXCAIRO_HOST_MEMORY_BYTES")
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
    squash = None; selection = None; selection_remaining = 0;
    icache = [||];
    runtime_hints = Hashtbl.create 8; page_hints = [||];
    code_pages = Hashtbl.create 8;
    code_seg = -1; code_base = 0; code_page = [||];
    watched = [||];
    allow_legacy_instructions = false;
    trace_on = trace;
    (* lazily committed; the two extra words are record_trace's headroom, so
       a power-of-two run of packed entries (a padded proof run) fits without
       doubling at every size *)
    trace = (if trace then seg_make ((if bounded_host then 65536 else 1 lsl 26) + 2) else empty_seg);
    tlen = 0;
    last_trace = 0;
    signatures = Hashtbl.create 8;
    builtins = [];
    tsegs = [||];
    thi = [||];
    ntsegs = 0;
    rules = [||];
    relocating = false;
    had_temp = false;
  }

let watch_segment vm seg length =
  if seg < 2 || seg >= vm.nsegs || length < 0 || length > vm.hi.(seg) then
    fail "Invalid watched contract bytecode segment";
  if seg >= Array.length vm.watched then begin
    let maps = Array.make vm.nsegs Bytes.empty in
    Array.blit vm.watched 0 maps 0 (Array.length vm.watched);
    vm.watched <- maps
  end;
  vm.watched.(seg) <- Bytes.make length '\000'

let[@inline] mark_watched vm seg off =
  if seg >= 2 && seg < Array.length vm.watched then
    let map = vm.watched.(seg) in
    if off >= 0 && off < Bytes.length map then Bytes.unsafe_set map off '\001'

let watched_range vm ptr length =
  let seg = rseg ptr and off = roff ptr in
  if seg < 2 || seg >= Array.length vm.watched then fail "Untracked bytecode segment";
  let map = vm.watched.(seg) in
  if length < 0 || off > Bytes.length map - length then fail "Invalid bytecode range";
  Segment.range_marked map off length

let add_segment vm =
  let n = vm.nsegs in
  if n >= Array.length vm.segs then begin
    let grow a d = Array.append a (Array.make (Array.length a) d) in
    vm.segs <- grow vm.segs empty_seg;
    vm.seg_flag <- grow vm.seg_flag k_plain;
    vm.hi <- grow vm.hi 0;
    vm.seg_builtin <- grow vm.seg_builtin None
  end;
  vm.segs.(n) <- seg_make (if n <> 1 then 16 else if bounded_host then 65536 else 1 lsl 27);
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
let[@inline] rule rules index =
  if index < Array.length rules then Array.unsafe_get rules index else Felt.empty

let[@inline] relocate_temp_value vm v =
  if v < Felt.empty && is_reloc v then begin
    let dst = rule vm.rules (temp_index (rseg v)) in
    if dst = Felt.empty then v else if is_felt dst then dst else
      let off = roff dst + roff v in
      if off > off_mask then fail "Offset exceeds range when relocating %d:%d" (rseg v) (roff v);
      reloc (rseg dst) off
  end else v

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
let add_relocation_rule ?(allow_felt=false) vm src dst =
  if not (is_reloc src) then fail "add_relocation_rule: src_ptr is not a relocatable";
  if not (is_reloc dst || (allow_felt && is_felt dst)) then fail "add_relocation_rule: dest_ptr is not a relocatable";
  if rseg src >= 0 then fail "Address %d is not in a temporary segment" (rseg src);
  if roff src <> 0 then fail "Non-zero offset %d in relocation source" (roff src);
  let k = temp_index (rseg src) in
  if k >= Array.length vm.rules then begin
    let grown = Array.make (max (k+1) (max 4 (2 * Array.length vm.rules))) Felt.empty in
    Array.blit vm.rules 0 grown 0 (Array.length vm.rules);
    vm.rules <- grown
  end;
  if vm.rules.(k) <> Felt.empty then fail "Duplicated relocation rule for segment %d" (rseg src);
  vm.rules.(k) <- dst;
  vm.relocating <- true

(* Memory.relocate_memory, run at the start of end_run: flatten rule chains,
   rewrite temporary relocatables in all memory, then move each relocated
   temporary segment into real memory (descending index order, holes skip
   addresses), with ordinary write-once and builtin validation. *)
external relocate_segments : seg array -> int array -> int -> Felt.t array -> bool
  = "cvm_relocate_segments" [@@noalloc]

let relocate_temp_memory ?on_resolved vm =
  if vm.relocating && vm.ntsegs > 0 then begin
    (* Resolve each rule once. Track active paths separately from felt destinations.
       Accumulate offsets when unwinding so shared tails reuse their result. *)
    let flat = Array.make (Array.length vm.rules) Felt.empty in
    let visiting = Bytes.make (Array.length flat) '\000' in
    let finish dst path =
      List.fold_left (fun base (k, delta) ->
          let v = if is_felt base then begin
              if delta <> 0 then fail "Nonzero offset in relocation chain to an integer";
              base
            end else
              let off = roff base + delta in
              if off > off_mask then fail "Offset exceeds range in relocation rule";
              reloc (rseg base) off in
          flat.(k) <- v; v) dst path |> ignore in
    let rec walk k path =
      let known = rule flat k in
      if known <> Felt.empty then finish known path else begin
        let dst = rule vm.rules k in
        if dst = Felt.empty then fail "Unmapped temporary segment %d" (-1-k);
        if is_felt dst || rseg dst >= 0 then begin flat.(k) <- dst; finish dst path end
        else begin
          if Bytes.get visiting k <> '\000' then fail "Relocation rule cycle";
          Bytes.set visiting k '\001';
          walk (temp_index (rseg dst)) ((k, roff dst) :: path)
        end
      end in
    Array.iteri (fun k v -> if v <> Felt.empty && flat.(k) = Felt.empty then walk k []) vm.rules;
    Option.iter (fun visit -> visit (fun ptr ->
        let base = rule flat (temp_index (rseg ptr)) in
        if base = Felt.empty then ptr else if is_felt base then base else
          let off = roff ptr + roff base in
          if off > off_mask then fail "Offset exceeds range when relocating access";
          reloc (rseg base) off)) on_resolved;
    if not (relocate_segments vm.segs vm.hi vm.nsegs flat &&
            relocate_segments vm.tsegs vm.thi vm.ntsegs flat) then
      fail "Offset exceeds range when relocating memory";
    let keep = ref [] in
    for k = vm.ntsegs - 1 downto 0 do
      let dst = rule flat k in
      if is_felt dst then () else if dst <> Felt.empty then begin
          let a = vm.tsegs.(k) in
          for i = 0 to vm.thi.(k) - 1 do
            let v = sget a i in
            if v <> Felt.empty then begin
              let o = roff dst + i in
              if o > off_mask then fail "Offset exceeds range when relocating memory";
              write_checked vm (rseg dst) o v
            end
          done
      end else keep := (vm.tsegs.(k), vm.thi.(k)) :: !keep
    done;
    let kept = Array.of_list !keep in
    vm.tsegs <- Array.map fst kept;
    vm.thi <- Array.map snd kept;
    vm.ntsegs <- Array.length kept;
    vm.rules <- [||];
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
