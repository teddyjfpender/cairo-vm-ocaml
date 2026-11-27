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
let () =
  let vm = create ~trace:false in
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
  assert (vm.tlen = 0)
