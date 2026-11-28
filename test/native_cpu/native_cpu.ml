open Cairovm
open Errors
open Segment
open Builtin
open Instruction
open Vm
open Deduce
open Cpu

(* Exercise the optimized interpreter with small segments. Compare committed
   instructions to step_instr and check that deoptimization commits no state. *)
let make_vm words cells =
  let segment items =
    let a = seg_make (Array.length items) in
    Array.iteri (sset a) items;
    a
  in
  let segs = [|segment words; segment cells; seg_make 8|] in
  let high cells = Array.fold_left (fun (i, n) v -> i+1, (if v = Felt.empty then n else i+1)) (0, 0) cells |> snd in
  { (create ~trace:false) with segs; nsegs=3; seg_flag=Array.make 3 k_plain;
    seg_builtin=Array.make 3 None; hi=[|high words; high cells; 0|];
    pc=0; ap=8; fp=6; trace_on=true; trace=seg_make 8 }

let encode flags dst op0 op1 =
  List.fold_left (fun v x -> Z.add (Z.shift_left v 16) (Z.of_int (x + 32768)))
    (Z.of_int flags) [op1; op0; dst]

let accepted = ref 0 and declined = ref 0

let compare flags offsets cells imm =
  let dst, a, b = offsets in
  let raw = encode flags dst a b in
  let words = [|Felt.of_z raw;imm|] in
  let vm = make_vm words cells and reference = make_vm words cells in
  (* shapes without a Stwo opcode component are rejected at decode since cairo-vm v4.0.0 *)
  match decode_word raw with
  | exception Generic_instruction -> ()
  | d ->
  let registers = [|0;8;6;vm.hi.(1);0;!Felt.pool_n;0;0;0|] in
  Felt.reserve 1;
  let steps = cpu_batch registers [|d;0;0;0|] vm.segs vm.seg_flag vm.hi vm.trace Felt.pool 3 true [||] in
  assert (steps = 0 || steps = 1);
  Felt.pool_n := registers.(5);
  if steps = 0 then incr declined
  else begin
    incr accepted;
    step_instr reference d
  end;
  assert (registers.(0) = reference.pc && registers.(1) = reference.ap && registers.(2) = reference.fp);
  assert (registers.(3) = reference.hi.(1) && registers.(4) = reference.tlen);
  for i = 0 to reference.tlen - 1 do assert (raw_get vm.trace i = raw_get reference.trace i) done;
  Array.iteri (fun seg mem ->
    if seg <> 1 then assert (vm.hi.(seg) = reference.hi.(seg));
    for i = 0 to slen mem - 1 do
      assert (Felt.equal (sget mem i) (sget reference.segs.(seg) i))
    done) vm.segs

let () =
  let rng = Random.State.make [|67231|] in
  let values = [|Felt.empty; Felt.zero; Felt.one; Felt.small 3; Felt.small (-4);
    Felt.of_z (Z.shift_left Z.one 180); Felt.reloc 2 1; Felt.reloc 1 9|] in
  let rand n = Random.State.int rng n in
  for _ = 1 to 4000 do
    let cells = Array.init 16 (fun _ -> values.(rand (Array.length values))) in
    let regs = rand 4 and src = [|0;1;2;4|].(rand 4) and result = rand 3 in
    let flags = 0x4000 lor regs lor (src lsl 2) lor (result lsl 5) lor (rand 2 lsl 11) in
    let delta () = rand 11 - 6 in
    compare flags (delta (), delta (), (if src = 1 then 1 else delta ())) cells (Felt.small 3)
  done;
  let cells = Array.make 16 Felt.one in
  cells.(8) <- Felt.empty; cells.(9) <- Felt.empty;
  compare 0x1104 (0,1,1) cells (Felt.small 2);
  cells.(4) <- Felt.reloc 1 4; cells.(5) <- Felt.reloc 0 4;
  compare 0x208b (-2,-1,-1) cells Felt.zero;
  compare 0x480a (0,-1,-3) cells Felt.zero;
  compare 0x0206 (-1,-1,1) cells (Felt.small 3);
  assert (!accepted > 100 && !declined > 100)

let () =
  let raw delta = encode 0x480a 0 (-1) delta in
  let words = Array.map Felt.of_z [|raw (-4); raw (-3); raw (-2)|] in
  let cache = Array.map (fun word -> decode_word (Felt.to_z word)) words in
  let execute ~hint ~hole =
    let cells = Array.make 16 Felt.empty in
    for i = 2 to 5 do cells.(i) <- Felt.small (i + 7) done;
    if hole then cells.(3) <- Felt.empty;
    let vm = make_vm words cells and reference = make_vm words cells in
    let code = Array.copy cache in
    if hint then code.(1) <- code.(1) lor hint_bit;
    let regs = [|0;8;6;vm.hi.(1);0;!Felt.pool_n;0;0;0|] in
    let n = cpu_batch regs code vm.segs vm.seg_flag vm.hi vm.trace Felt.pool 3 true [||] in
    assert (n = if hint || hole then 1 else 3);
    for i = 0 to n-1 do step_instr reference cache.(i) done;
    assert (regs.(0) = reference.pc && regs.(1) = reference.ap && regs.(3) = reference.hi.(1));
    for i = 0 to 15 do assert (sget vm.segs.(1) i = sget reference.segs.(1) i) done;
    for i = 0 to n-1 do assert (raw_get vm.trace i = raw_get reference.trace i) done
  in
  execute ~hint:false ~hole:false;
  execute ~hint:true ~hole:false;
  execute ~hint:false ~hole:true

let () =
  List.iter (fun (kind, width, expected) ->
    let vm = make_vm [|Felt.zero|] (Array.make 16 Felt.empty) in
    let b = {kind; base=2; stop_ptr=width; cache=[||]} in
    vm.builtins <- [b];
    vm.seg_flag.(2) <- flag_of kind;
    write vm 2 0 (Felt.small 7); write vm 2 1 (Felt.small 3);
    let deduced = deduce_builtin vm b 2 2 in
    Option.iter (fun n -> assert (Felt.equal deduced (Felt.small n))) expected;
    write vm 2 2 deduced;
    Resources.verify_auto_deductions vm;
    (* Simulate a program-supplied output with both warm and cold caches. *)
    sset vm.segs.(2) 2 (Felt.small 123);
    let reject () = match Resources.verify_auto_deductions vm with
      | exception Vm_error _ -> () | () -> failwith "accepted incorrect builtin output"
    in
    reject (); b.cache <- [||]; reject ())
    [Bitwise,5,Some 3; Pedersen,3,None]

let () =
  (* A low-level caller may use the first program word as its stop address. *)
  let jump = encode 0x0107 (-1) (-1) 1 in
  let words = [|Felt.zero; Felt.zero; Felt.of_z jump; Felt.small (-2)|] in
  let vm = make_vm words (Array.make 16 Felt.one) in
  vm.pc <- 2;
  vm.icache <- [|0; 0; decode_word jump; 0|];
  run ~stop:(0, 0) vm (Array.make 4 [||]);
  assert (vm.steps = 1 && vm.pc_seg = 0 && vm.pc = 0 && vm.tlen = 1)

let () =
  (* Bounded runs end exactly, beyond one batch too; a cached stop pc stops
     the kernel and stays unflagged afterwards. *)
  let jump = encode 0x0107 (-1) (-1) 1 in
  let words = [|Felt.of_z jump; Felt.small 2; Felt.of_z jump; Felt.small (-2)|] in
  let vm = make_vm words (Array.make 16 Felt.one) in
  vm.icache <- [|decode_word jump; 0; decode_word jump; 0|];
  run ~stop:(0, 2) vm [||];
  assert (vm.steps = 1 && vm.pc = 2 && vm.icache.(2) = decode_word jump);
  run ~steps:10_001 vm [||];
  assert (vm.steps = 10_002 && vm.pc = 0 && vm.tlen = 10_002)

(* Install CASM hints after the contract's instruction page has been decoded.
   Both jumps stay in the same segment and cross the native batch boundary. *)
let check_watched_code trace =
  let vm = create ~trace in
  ignore (add_segment vm); ignore (add_segment vm);
  let code = add_segment vm in
  let jump = Felt.of_z (Z.of_string "0x10780017fff7fff") in
  Array.iteri (write vm code) [|jump; Felt.small 2; jump; Felt.small (-2)|];
  write vm code 4 Felt.one;
  watch_segment vm code 5;
  write vm 1 0 Felt.one;
  vm.ap <- 1; vm.fp <- 1; vm.pc_seg <- code;
  run ~steps:8200 vm [||];
  assert (vm.pc = 0);
  let counters = Array.make 2 0 in
  Array.iteri (fun i pc ->
      register_runtime_hints vm ~segment:code ~pc
        [|(fun current -> assert (current.pc = pc); counters.(i) <- counters.(i) + 1)|]) [|0; 2|];
  run ~steps:18000 vm [||];
  assert (vm.pc = 0 && counters = [|9000; 9000|]);
  for i = 0 to 3 do assert (watched_range vm (Felt.reloc code i) 1) done;
  assert (not (watched_range vm (Felt.reloc code 4) 1));
  if trace then begin
    assert (vm.tlen = 26200);
    for i = 0 to vm.tlen - 1 do
      let next, seg, pc, ap, fp = Resources.trace_entry vm.trace i in
      assert (next = i+1 && seg = code && pc = 2 * (i mod 2) && ap = 1 && fp = 1)
    done
  end else assert (vm.tlen = 0)

let () = List.iter check_watched_code [false; true]

let () =
  let vm = create ~trace:false in
  let base = add_segment vm in
  let first = add_temp_segment vm and second = add_temp_segment vm in
  let ptr = Felt.reloc in
  write_checked vm first 0 Felt.one;
  write_checked vm second 0 (ptr first 3);
  write_checked vm base 0 (ptr second 1);
  add_relocation_rule vm (ptr first 0) (ptr second 4);
  add_relocation_rule vm (ptr second 0) (ptr base 10);
  assert (get vm base 0 = ptr base 11);
  assert (relocate_temp_value vm (ptr first 3) = ptr second 7);
  relocate_temp_memory vm;
  assert (get vm base 10 = ptr base 17);
  assert (get vm base 14 = Felt.one);
  let cycle = add_temp_segment vm in
  add_relocation_rule vm (ptr cycle 0) (ptr cycle 0);
  match relocate_temp_memory vm with
  | exception Errors.Vm_error _ -> ()
  | () -> failwith "accepted cyclic temporary segment relocation"

external batch_poseidon : int array -> int array -> seg array -> flag array -> int array ->
  seg -> Felt.pool -> int -> bytes array -> Felt.t array -> Felt.t array -> int
  = "cvm_cpu_batch_poseidon_byte" "cvm_cpu_batch_poseidon" [@@noalloc]

let () =
  (* A run copies each independent result onto the execution stack twice.
     The last instruction consumes a copy arithmetically, forcing the batch
     to expose the exact synchronous state at that boundary. *)
  let n = 96 in
  let words = Array.init (2*n+2) (fun i ->
      if i = 2*n then encode 0x4824 0 (-1) 1
      else if i = 2*n+1 then Z.one
      else if i mod 2 = 0 then encode 0x4802 0 (-3) (6*(i/2)+3)
      else encode 0x4812 0 (-1) (-1)) in
  let cache = Array.mapi (fun i z -> if i = 2*n+1 then 0 else decode_word z) words in
  let make () =
    let stack = Array.make (2*n+32) Felt.empty in
    stack.(3) <- Felt.reloc 2 0;
    stack.(5) <- Felt.one;
    let vm = {(make_vm (Array.map Felt.of_z words) stack) with trace_on=false} in
    let cells = seg_make (6*n) in
    for i = 0 to n-1 do
      for k = 0 to 2 do sset cells (6*i+k) (Felt.small (4*i+k)) done
    done;
    vm.segs.(2) <- cells;
    vm.hi.(2) <- 6*n-3;
    let builtin = {kind=Poseidon; base=2; stop_ptr=(-1); cache=Array.make (6*n) Felt.empty} in
    vm.builtins <- [builtin]; vm.seg_builtin.(2) <- Some builtin;
    vm.seg_flag.(2) <- flag_of Poseidon;
    vm,builtin
  in
  let vm,b = make () and ref_vm,ref_b = make () in
  let state = [|0;8;6;vm.hi.(1);0;!Felt.pool_n;0;0;0;0;0;0;1|] in
  let steps = batch_poseidon state cache vm.segs vm.seg_flag vm.hi vm.trace Felt.pool 3 [||] [||] b.cache in
  assert (steps = 2*n);
  Felt.pool_n := state.(5);
  for _ = 1 to steps do Cpu.step_instr ref_vm cache.(ref_vm.pc) done;
  assert (state.(0) = ref_vm.pc && state.(1) = ref_vm.ap && state.(3) = ref_vm.hi.(1));
  assert (Array.for_all2 Felt.equal b.cache ref_b.cache);
  Array.iteri (fun s seg ->
      for i = 0 to slen seg-1 do assert (Felt.equal (sget seg i) (sget ref_vm.segs.(s) i)) done) vm.segs

let () =
  let vm = create ~trace:false in
  let real = add_segment vm and dst = add_temp_segment vm in
  let intermediate = add_temp_segment vm in
  let ptr = Felt.reloc in
  (match add_relocation_rule vm (ptr dst 0) Felt.one with
   | exception Vm_error _ -> () | () -> failwith "ordinary VM accepted integer destination");
  add_relocation_rule ~allow_felt:true vm (ptr dst 0) Felt.one;
  add_relocation_rule vm (ptr intermediate 0) (ptr dst 0);
  write_checked vm real 0 (ptr intermediate 21);
  write_checked vm dst 0 (Felt.small 7);
  assert (get vm dst 0 = Felt.small 7 && relocate_temp_value vm (ptr dst 17) = Felt.one);
  relocate_temp_memory vm;
  assert (get vm real 0 = Felt.one && vm.ntsegs = 0);
  let a = add_temp_segment vm and b = add_temp_segment vm in
  add_relocation_rule vm (ptr a 0) (ptr b 1);
  add_relocation_rule ~allow_felt:true vm (ptr b 0) Felt.one;
  match relocate_temp_memory vm with
  | exception Vm_error _ -> () | () -> failwith "accepted nonzero hop to an integer destination"

(* The same operand is copied, dereferenced and used for deduction while
   its segment is temporary. Install a rule between batches and compare
   both pointer and integer relocation with the generic interpreter. *)
let () =
  let push = encode 0x480a 0 (-1) (-3) in
  let indirect offset = encode 0x4802 0 (-3) offset in
  let words = [|push; indirect 2; indirect 3; push|] in
  let make () =
    let cells = Array.make 16 Felt.empty in
    cells.(5) <- Felt.one;
    cells.(10) <- Felt.small 91;
    let vm = make_vm (Array.map Felt.of_z words) cells in
    let tmp = add_temp_segment vm in
    write vm 1 3 (Felt.reloc tmp 0);
    write_checked vm tmp 2 (Felt.small 27);
    vm.icache <- Array.map decode_word words;
    vm, tmp in
  List.iter (fun destination ->
    let vm, tmp = make () and ref_vm, ref_tmp = make () in
    let before = !generic_steps in
    run ~stop:(0,3) vm [||];
    for _ = 1 to 3 do step ref_vm done;
    assert (!generic_steps = before);
    assert (vm.thi.(0) = 4 && get vm tmp 3 = Felt.small 91);
    assert (read vm 1 8 = Felt.reloc tmp 0 && read vm 1 9 = Felt.small 27);
    add_relocation_rule ~allow_felt:true vm (Felt.reloc tmp 0) destination;
    add_relocation_rule ~allow_felt:true ref_vm (Felt.reloc ref_tmp 0) destination;
    run ~stop:(0,4) vm [||]; step ref_vm;
    assert (get vm 1 11 = destination && vm.pc = ref_vm.pc && vm.ap = ref_vm.ap);
    assert (vm.thi = ref_vm.thi && vm.tlen = ref_vm.tlen);
    for i = 0 to 15 do assert (read vm 1 i = read ref_vm 1 i) done;
    for i = 0 to vm.tlen-1 do assert (raw_get vm.trace i = raw_get ref_vm.trace i) done)
    [Felt.reloc 2 3; Felt.small 42]

(* cairo-vm 3.2 accepts a conditional jump with its distance in a stack
   cell. v4's opcode classifier requires an immediate distance. *)
let () =
  let word = Felt.of_z (Z.of_string "0x2127ffe7fff7fff") in
  let cells = Array.make 16 Felt.zero in
  cells.(5) <- Felt.one;
  cells.(6) <- Felt.small 4;
  let vm = make_vm [|word|] cells in
  (match Cpu.step vm with
   | exception Vm_error _ -> ()
   | () -> failwith "generic instruction admitted by default");
  vm.allow_legacy_instructions <- true;
  Cpu.step vm;
  assert (vm.pc = 1 && vm.steps = 1 && vm.tlen = 1);
  assert (Array.length vm.icache = 0 || vm.icache.(0) = 0);
  vm.pc <- 0;
  Segment.sset vm.segs.(1) 7 Felt.one;
  Cpu.step vm;
  assert (vm.pc = 4 && vm.steps = 2);
  assert (Array.length vm.icache = 0 || vm.icache.(0) = 0)
external select_rows : int array -> int array -> seg array -> flag array -> int array ->
  Felt.pool -> int -> Bytes.t array -> int = "cvm_selection_rows_byte" "cvm_selection_rows" [@@noalloc]

let () =
  let raw = [| "0x20780017fff7ffd";"4";"0x480a7ffb7fff8000";"0x208b7fff7fff7ffe";
    "0x40780017fff7fff";"3";"0x404b800080008000";"0x400380007ff98001";"0x400380007ffa8002";
    "0x20780017fff8000";"4";"0x10780017fff7fff";"4";"0x400380007ffb8001";"0x400380007ffc8002";
    "0x482680017ff98000";"1";"0x482680017ffa8000";"1";"0x482a80007ffb8000";"0x482a80007ffc8000";
    "0x482680017ffd8000";"-1";"0x1104800180018000";"-23";"0x208b7fff7fff7ffe" |] in
  let words = Array.map (fun s-> Felt.of_z (Z.of_string s)) raw in
  let op = [0;2;3;4;6;7;8;9;11;13;14;15;17;19;20;21;23;25] in
  let state size =
    let basic = make_vm words (Array.make size Felt.empty) in
    let segs = Array.init 6 (fun i-> if i<2 then basic.segs.(i) else seg_make 16) in
    let vm={basic with pc=6; ap=19; fp=16; trace_on=false; segs; nsegs=6;
            seg_flag=Array.make 6 k_plain; seg_builtin=Array.make 6 None;
            hi=Array.init 6 (fun i->if i=0 then Array.length words else 0);
            watched=Array.init 6 (fun _->Bytes.make 16 '\000'); icache=Array.make 26 0} in
    List.iter (fun i -> vm.icache.(i)<-decode_word (Felt.to_z words.(i))) op;
    vm.icache.(6)<-vm.icache.(6) lor hint_bit;
    List.iteri (fun i s-> write vm 1 (9+i) (Felt.reloc s 0)) [2;3;4;5];
    write vm 1 13 (Felt.small 6); write vm 1 14 (Felt.reloc 1 0); write vm 1 15 (Felt.reloc 0 25);
    for i=0 to 5 do write vm 2 i (Felt.small (i*3)); write vm 3 i (Felt.reloc 3 i) done;
    List.iteri (fun i n -> write vm 4 i (Felt.small n)) [0;9;15];
    vm in
  let hint vm remaining =
    let ptr i=get vm 1 (vm.fp+i) in
    let readptr i=let v=ptr i in get vm (Felt.rseg v) (Felt.roff v) in
    let c= !remaining>0 && Felt.equal (readptr (-7)) (readptr (-5)) in
    write vm 1 vm.fp (if c then Felt.one else Felt.zero);
    if c then decr remaining in
  let cases = ref 0 and multi = ref 0 in
  let verify size initial tweak =
    let vm=state size and refvm=state size in
    let remaining=ref initial in hint vm remaining; let remref=ref initial in hint refvm remref;
    tweak vm; tweak refvm;
    let regs=Array.make 17 0 in
    regs.(0)<-vm.pc; regs.(1)<-vm.ap; regs.(2)<-vm.fp; regs.(3)<-vm.hi.(1); regs.(15)<- !remaining;
    let steps=select_rows regs vm.icache vm.segs vm.seg_flag vm.hi Felt.pool vm.nsegs vm.watched in
    for i=0 to steps-1 do
      if i>0 && refvm.pc=6 then hint refvm remref;
      step_instr refvm (refvm.icache.(refvm.pc) land lnot hint_bit)
    done;
    assert(regs.(15)= !remref && regs.(0)=refvm.pc && regs.(1)=refvm.ap &&
           regs.(2)=refvm.fp && regs.(3)=refvm.hi.(1));
    vm.hi.(1)<-regs.(3);
    Array.iteri (fun k seg ->
      assert(vm.hi.(k)=refvm.hi.(k)); assert(vm.watched.(k)=refvm.watched.(k));
      for i=0 to slen seg-1 do assert(Felt.equal (sget seg i) (sget refvm.segs.(k) i)) done) vm.segs;
    incr cases; if regs.(16)>0 then incr multi;
    steps in
  let no _=() in
  assert(verify 128 3 no>60);
  List.iter (fun s-> List.iter (fun n -> ignore(verify s n no)) [0;1;2;3;7]) [24;25;26;35;36;45;66;128];
  for k=0 to 25 do ignore(verify 128 3 (fun vm->vm.icache.(k)<-vm.icache.(k) lor hint_bit)) done;
  for k=17 to 85 do
    List.iter (fun v -> ignore(verify 128 3 (fun vm->write vm 1 k v)))
      [Felt.one;Felt.small (-2);Felt.reloc 1 0]
  done;
  for k=0 to 5 do
    List.iter (fun s-> ignore(verify 128 3 (fun vm->sset vm.segs.(s) k Felt.empty))) [2;3;4];
    List.iter (fun v->ignore(verify 128 3 (fun vm->write vm 5 k v))) [Felt.small 2;Felt.reloc 3 k]
  done;
  List.iter (fun s->ignore(verify 128 3 (fun vm->sset vm.segs.(1) 12 (Felt.reloc s 0)))) [0;2;3;4;5];
  let check_run extra stop budget =
    let setup () =
      let vm=state 128 and remaining=ref 3 and observed=ref 0 in
      sset vm.segs.(1) 15 (Felt.reloc 0 26);
      let rec action vm =
        hint vm remaining;
        vm.selection_remaining <- !remaining;
        vm.selection <- armed
      and descriptor={action;publish=(fun n->remaining:=n)}
      and armed=Some descriptor in
      let handlers=Array.make 26 [||] in
      handlers.(6)<-(if extra then [|action;(fun _->incr observed)|] else [|action|]);
      vm,remaining,observed,handlers in
    let vm,n,o,handlers=setup() and reference,nr,orr,refhandlers=setup() in
    run ~stop:(0,stop) ~steps:budget vm handlers;
    while reference.pc<>stop && reference.steps<budget do
      Array.iter (fun f->f reference) refhandlers.(reference.pc);
      step_instr reference (reference.icache.(reference.pc) land lnot hint_bit)
    done;
    assert(vm.pc=reference.pc && vm.fp=reference.fp && vm.ap=reference.ap &&
           vm.steps=reference.steps && vm.hi=reference.hi && vm.watched=reference.watched &&
           !n= !nr && !o= !orr && vm.selection=None);
    Array.iteri (fun k seg->for i=0 to slen seg-1 do
        assert(Felt.equal (sget seg i) (sget reference.segs.(k) i))
      done) vm.segs in
  List.iter (fun extra->
    List.iter (fun stop->check_run extra stop 8192) [0;2;4;6;7;9;11;13;15;20;23;25;26];
    List.iter (check_run extra 26) [0;1;2;10;12;13;25;55;77;8191;8192;10000]) [false;true];
  Printf.printf "checked %d selection states, %d fused multiple hints\n" !cases !multi

external batch_watched : int array -> int array -> seg array -> flag array -> int array ->
  seg -> Felt.pool -> int -> Bytes.t array -> Felt.t array -> int =
  "cvm_cpu_batch_watched_byte" "cvm_cpu_batch_watched" [@@noalloc]

let () =
  let raw=[|"0x48297ffb80007ffc";"0x48487ffd80007fff";"0x400280007ffa7fff";
    "0x482680017ffa8000";"1";"0x208b7fff7fff7ffe";"0x20780017fff7ffd";"4";"0x480a7ff97fff8000";
    "0x208b7fff7fff7ffe";"0x480a7ff97fff8000";"0x480280007ffa8000";"0x480280007ffb8000";
    "0x480280007ffc8000";"0x1104800180018000";"-14";"0x482680017ffa8000";"1";
    "0x482680017ffb8000";"1";"0x482680017ffc8000";"1";"0x482680017ffd8000";"-1";
    "0x1104800180018000";"-18";"0x208b7fff7fff7ffe"|] in
  let words=Array.map (fun s->Felt.of_z (Z.of_string s)) raw in
  let ops=[0;1;2;3;5;6;8;9;10;11;12;13;14;16;18;20;22;24;26] in
  let state size count =
    let basic=make_vm words (Array.make size Felt.empty) in
    let segs=Array.init 6 (fun k->if k<2 then basic.segs.(k) else seg_make 16) in
    let vm={basic with pc=6;fp=16;ap=17;segs;nsegs=6;trace_on=false;seg_flag=Array.make 6 k_plain;
      icache=Array.make 27 0;seg_builtin=Array.make 6 None;
      hi=Array.init 6 (fun i->if i=0 then Array.length words else 0);
      watched=Array.init 6 (fun _->Bytes.make 16 '\000')} in
    List.iter (fun i->vm.icache.(i)<-decode_word (Felt.to_z words.(i))) ops;
    List.iteri (fun i s->write vm 1 (9+i) (Felt.reloc s 0)) [2;3;4;5];
    write vm 1 13 (Felt.small count); write vm 1 14 (Felt.reloc 1 3); write vm 1 15 (Felt.reloc 0 27);
    vm.seg_flag.(2)<-flag_of Range_check;
    for i=0 to 8 do
      let value off=if i mod 2=0 then Felt.reloc (11+i) off else Felt.small off in
      write vm 3 i (value i); write vm 4 i (value (i+i*3)); write vm 5 i (Felt.small 3)
    done; vm in
  let tests=ref 0 in
  let verify size n tweak =
    let vm=state size n and reference=state size n in
    tweak vm;tweak reference;
    let regs=[|vm.pc; vm.ap; vm.fp; vm.hi.(1);0;!Felt.pool_n;0;0;0;0;0;0;0;0;0|] in
    let count=batch_watched regs vm.icache vm.segs vm.seg_flag vm.hi vm.trace Felt.pool vm.nsegs vm.watched [||] in
    for i=0 to count-1 do
      let d=reference.icache.(reference.pc) in
      if i>0 then assert(d land hint_bit=0);
      step_instr reference (d land lnot hint_bit)
    done;
    vm.hi.(1)<-regs.(3);
    assert(regs.(0)=reference.pc && regs.(1)=reference.ap && regs.(2)=reference.fp && vm.hi=reference.hi);
    Array.iteri (fun k seg ->
      Bytes.iteri (fun i bit ->
        let actual=Bytes.get vm.watched.(k) i in
        if actual<>bit then begin
          (* The native interpreter can probe the next indirect operand before
             returning it to scalar deduction. It can mark only that address. *)
          assert(bit='\000' && actual='\001');
          let d=reference.icache.(reference.pc) in
          assert((d lsr 50) land 3=0);
          let base=if d land (1 lsl 49)<>0 then reference.fp else reference.ap in
          let ptr=get reference 1 (base+((d lsr 16) land 0xffff)-32768) in
          assert(Felt.is_reloc ptr && Felt.rseg ptr=k &&
                 Felt.roff ptr+((d lsr 32) land 0xffff)-32768=i)
        end) reference.watched.(k);
      for i=0 to slen seg-1 do assert(Felt.equal (sget seg i) (sget reference.segs.(k) i)) done) vm.segs;
    incr tests; count in
  let no _=() in
  assert(verify 220 8 no>128);
  List.iter (fun size -> List.iter (fun n->ignore(verify size n no)) [0;1;2;5;8]) [22;32;47;63;78;93;110;220];
  List.iter (fun k->ignore(verify 220 8 (fun vm->vm.icache.(k)<-vm.icache.(k) lor hint_bit))) ops;
  for i=17 to 120 do
    List.iter (fun v->ignore(verify 220 8 (fun vm->write vm 1 i v))) [Felt.one;Felt.small (-1);Felt.reloc 1 2]
  done;
  for i=0 to 7 do
    List.iter (fun s-> List.iter (fun v->ignore(verify 220 8 (fun vm->sset vm.segs.(s) i v)))
      [Felt.empty;Felt.small (-3);Felt.zero;Felt.reloc 7 4]) [3;4;5];
    List.iter (fun v ->ignore(verify 220 8 (fun vm->write vm 2 i v))) [Felt.zero;Felt.small i]
  done;
  Printf.printf "checked %d validation states against scalar interpreter\n" !tests
