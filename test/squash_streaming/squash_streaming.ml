open Cairovm
open Vm
open Segment
open Builtin

external rows : int array -> int array -> seg array -> flag array -> int array -> Felt.pool ->
  int -> Bytes.t array -> int list -> int -> Felt.t array -> seg array -> int -> int =
  "cvm_squash_rows_byte" "cvm_squash_rows" [@@noalloc]

let program =
  Array.map (fun s->Felt.of_z (Z.of_string s))
    [|"0x480080007fff8000";"0x482480017fff8000";"1";"0x484480017fff8000";"3";
      "0x48307fff7ffb8002";"0x4000800180017ff9";"0x4800800280018000";"0x4001800080007ffa";
      "0x482480017ffa8001";"1";"0xa0680017fff7ffd";"-11"|]
let ops=[0;1;3;5;6;7;8;9;11]

let make ~n ~slots ~temporary =
  let vm=create ~trace:false in
  let a=Array.init 4 (fun i->seg_make (match i with 0->13|1->slots|2->3*(2*n+2)|_->n+8)) in
  let vm={vm with nsegs=4;segs=a;seg_flag=[|k_plain;k_plain;k_plain;flag_of Range_check|];
       seg_builtin=Array.make 4 None;hi=Array.make 4 0;fp=16;ap=24;pc=0;
       icache=Array.make 13 0;watched=Array.map (fun seg->Bytes.make (slen seg) '\000') a} in
  let ds=if temporary then begin
      vm.tsegs<-[|seg_make (3*(2*n+2))|];vm.thi<-[|0|];vm.ntsegs<-1; -1
    end else 2 in
  Array.iteri (write vm 0) program;
  List.iter (fun i->vm.icache.(i)<-Instruction.decode_word (Felt.to_z program.(i))) ops;
  List.iter (fun i->vm.icache.(i)<-vm.icache.(i) lor Cpu.hint_bit) [0;11];
  let key=Felt.of_z Z.(shift_left one 218) in
  let value i=if i mod 5=0 then Felt.reloc 2 i else Felt.small (i-1024) in
  let indices=List.init n (fun i-> 1+2*i) in
  List.iteri (fun i loc->
      let at=3*loc in
      write_checked vm ds at key;write_checked vm ds (at+1) (value i);
      write_checked vm ds (at+2) (value (i+1))) indices;
  write vm 1 15 (Felt.reloc 0 13);
  write vm 1 10 key;write vm 1 21 (value 0);
  write vm 1 22 (Felt.reloc ds 0);write vm 1 23 (Felt.reloc 3 0);
  write vm 1 24 Felt.zero;
  vm,indices

let verify ?(slots=180) ?(n=17) ?(temporary=false) tweak =
  let vm,indices=make ~n ~slots ~temporary and reference,_=make ~n ~slots ~temporary in
  tweak vm;tweak reference;
  let initial=List.hd indices and rest=List.tl indices in
  let regs=Array.make 17 0 in
  regs.(0)<-vm.pc;regs.(1)<-vm.ap;regs.(2)<-vm.fp;regs.(3)<-vm.hi.(1);regs.(15)<-initial;
  let steps=rows regs vm.icache vm.segs vm.seg_flag vm.hi Felt.pool vm.nsegs
      vm.watched rest initial vm.rules vm.tsegs vm.ntsegs in
  let current=ref initial and pending=ref rest in
  for i=0 to steps-1 do
    if i>0 && reference.pc=0 then begin
      let next=List.hd !pending in pending:=List.tl !pending;
      write reference 1 reference.ap (Felt.small (next- !current-1));current:=next
    end;
    if reference.pc=11 then
      write reference 1 (reference.ap-3) (if !pending=[] then Felt.zero else Felt.one);
    Cpu.step_instr reference (reference.icache.(reference.pc) land lnot Cpu.hint_bit)
  done;
  vm.hi.(1)<-regs.(3);
  assert(steps<=8192 && regs.(0)=reference.pc && regs.(1)=reference.ap &&
         regs.(2)=reference.fp && regs.(15)= !current && vm.hi=reference.hi &&
         vm.thi=reference.thi && vm.watched=reference.watched);
  let same a b=Array.iteri(fun k s->for i=0 to slen s-1 do
      assert(Felt.equal (sget s i) (sget b.(k) i))
    done) a in
  same vm.segs reference.segs; same vm.tsegs reference.tsegs;
  steps

let () =
  let no _=() in
  List.iter (fun temporary->
      assert(verify ~temporary no=17*9);
      assert(verify ~n:950 ~slots:7000 ~temporary no=910*9);
      for slots=25 to 87 do ignore(verify ~slots ~temporary no) done) [false;true];
  assert(verify (fun vm->sset vm.segs.(1) 15 Felt.empty)=0);
  List.iter (fun i->assert(verify (fun vm->vm.icache.(i)<-0)=0)) ops;
  List.iter (fun i->assert(verify (fun vm->vm.icache.(i)<-vm.icache.(i) lor Cpu.hint_bit)=0))
    [1;3;5;6;7;8;9];
  for i=25 to 115 do ignore(verify(fun vm->write vm 1 i (Felt.small (-5)))) done;
  for i=0 to 16 do
    let idx=3*(2*i+1) in
    List.iter(fun k->ignore(verify(fun vm->sset vm.segs.(2) (idx+k) Felt.empty))) [0;1;2];
    ignore(verify(fun vm->write vm 3 i (Felt.small 88)))
  done;
  assert(verify ~temporary:true (fun vm->Vm.add_relocation_rule vm (Felt.reloc (-1) 0) (Felt.reloc 2 0))=0);
  print_endline "Streaming squash rows match scalar registers, hints, memory, high-water marks and access maps"

let run_public ~extra ~stop ~budget ~corrupt =
  let setup () =
    let vm,indices=make ~n:17 ~slots:180 ~temporary:false in
    let open Program in
    let reference={r_group=5;r_offset=0;r_expr=Cast(Reg_ap,"scope.LoopTemps*")} in
    let typ={i_type="struct";i_value=None;i_pc=None;i_destination=None;
             i_members=["index_delta_minus1",0;"should_continue",3];i_member_types=[]} in
    let ids=Hashtbl.create 1 in Hashtbl.add ids "scope.LoopTemps" typ;
    let prog={data=Array.map Felt.to_z program;builtins=[];main=Some 0;start=None;
              end_=None;hints=[];references=[|reference|];identifiers=ids} in
    let scopes=Hintrt.new_scopes () and seen=ref 0 in
    Hintrt.enter scopes ["current_access_indices",Hintrt.Ints indices;
                        "current_access_index",Hintrt.Int Z.zero];
    let hints=Array.make 13 [||] in
    List.iter (fun (pc,code,offset)->
        let h={code;scopes=["scope"];h_group=5;h_offset=offset;ref_ids=["scope.loop_temps",0]} in
        let f=Hints.compile prog scopes h in
        hints.(pc)<-if extra=pc then [|f;(fun _->incr seen)|] else [|f|])
      [0,Hint_codes.squash_dict_inner_check_access_index,0;
       11,Hint_codes.squash_dict_inner_continue_loop,6];
    if corrupt then write vm 3 4 (Felt.small 991);
    vm,scopes,hints,seen in
  let vm,scopes,hints,seen=setup() and refvm,rscopes,rhints,rseen=setup() in
  let observe f=try f();None with Errors.Vm_error message->Some message in
  let outcome=observe(fun ()->Cpu.run ~stop:(0,stop) ~steps:budget vm hints) in
  let expected=observe(fun ()->
    while refvm.pc<>stop && refvm.steps<budget do
      Array.iter (fun f->f refvm) rhints.(refvm.pc);
      Cpu.step_instr refvm (refvm.icache.(refvm.pc) land lnot Cpu.hint_bit)
    done) in
  assert(outcome=expected && !seen= !rseen && vm.pc=refvm.pc && vm.fp=refvm.fp &&
         vm.ap=refvm.ap && vm.steps=refvm.steps && vm.hi=refvm.hi && vm.watched=refvm.watched);
  List.iter(fun name->assert(Hintrt.var scopes name=Hintrt.var rscopes name))
    ["current_access_indices";"current_access_index"];
  Array.iteri(fun k seg->for i=0 to slen seg-1 do
    assert(Felt.equal (sget seg i) (sget refvm.segs.(k) i))
  done) vm.segs

let () =
  List.iter (fun extra->
      List.iter (fun stop->run_public ~extra ~stop ~budget:8192 ~corrupt:false) (13::ops);
      List.iter (fun budget->run_public ~extra ~stop:13 ~budget ~corrupt:false)
        [0;1;8;9;10;18;122;8191;8192;8193];
      run_public ~extra ~stop:13 ~budget:8192 ~corrupt:true)
    [-1;0;11];
  print_endline "Public scalar parity covers stops, step budgets, extra callbacks and mid-stream rejection"
