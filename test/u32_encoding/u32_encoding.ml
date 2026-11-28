open Cairovm

external blake_u32_words : Felt.pool -> Felt.t -> int array -> int
  = "cvm_blake_u32_words" [@@noalloc]

let limbs () =
  let edge bits = Z.shift_left Z.one bits in
  let values = [ Z.zero; Z.one; Z.neg Z.one; Z.pred Felt.p;
                 Z.pred (edge 59); edge 59; Z.pred (edge 63); edge 63;
                 edge 128; Z.succ (edge 191); Z.succ (edge 250) ] in
  List.iter (fun input ->
      let felt = Felt.of_z input and words = Array.make 8 0 in
      let size = blake_u32_words Felt.pool felt words in
      let value = Felt.to_z felt in
      let expected = if Z.lt value (edge 63) then value else Z.add value (edge 255) in
      assert (size = if Z.lt value (edge 63) then 2 else 8);
      let got = Array.fold_left (fun n word -> Z.add (Z.shift_left n 32) (Z.of_int word))
          Z.zero (Array.sub words 0 size) in
      assert (Z.equal got expected)) values

external batch : int array -> int array -> Segment.seg array -> Builtin.flag array -> int array ->
  Segment.seg -> Felt.pool -> int -> Bytes.t array -> Felt.t array -> int =
  "cvm_cpu_batch_watched_byte" "cvm_cpu_batch_watched" [@@noalloc]

let encoded flags dst op0 op1 =
  List.fold_left (fun v x -> Z.add (Z.shift_left v 16) (Z.of_int (x+32768)))
    (Z.of_int flags) [op1;op0;dst]

let words = [|encoded 0x4800 0 (-8) 1; encoded 0x4831 0 0 (-1);
              encoded 0x4000 (-1) (-11) 2; encoded 0x4800 0 (-12) 3;
              encoded 0x4844 0 (-1) 1; Z.shift_left Z.one 32;
              encoded 0x4830 (-4) 0 (-1); encoded 0x4000 (-1) (-15) 4|]

let state tracing x =
  let open Segment in
  let open Vm in
  let segs = Array.init 5 (fun _ -> seg_make 64) in
  let vm = { (create ~trace:tracing) with segs; nsegs=5; seg_flag=Array.make 5 Builtin.k_plain;
    seg_builtin=Array.make 5 None; hi=Array.make 5 0; ap=24; fp=6; trace=seg_make 64;
    icache=Array.make 8 0; watched=Array.init 5 (fun _ -> Bytes.make 64 '\000') } in
  Array.iteri (fun i z ->
      write vm 0 i (Felt.of_z z);
      if i <> 5 then vm.icache.(i) <- Instruction.decode_word z) words;
  vm.seg_flag.(3) <- Builtin.flag_of Builtin.Range_check;
  write vm 1 vm.fp (Felt.of_z (Z.pred (Z.shift_left Z.one 63)));
  write vm 1 (vm.ap-8) (Felt.reloc 2 0);
  write vm 1 (vm.ap-9) (Felt.reloc 3 0);
  write vm 1 (vm.ap-10) (Felt.reloc 4 0);
  write vm 2 1 (Felt.of_z x);
  write vm 4 3 (Felt.of_z (Z.shift_right x 32));
  write vm 4 4 (Felt.of_z (Z.extract x 0 32));
  vm

let compare tracing x alter =
  let open Segment in
  let a=state tracing x and b=state tracing x in
  alter a; alter b;
  let regs=Array.make 17 0 in
  regs.(1)<-a.ap; regs.(2)<-a.fp; regs.(3)<-a.hi.(1);
  regs.(5)<- !Felt.pool_n; regs.(14)<-Bool.to_int tracing;
  Felt.reserve 16;
  let n=batch regs a.icache a.segs a.seg_flag a.hi a.trace Felt.pool a.nsegs a.watched [||] in
  Felt.pool_n:=regs.(5);
  for _=1 to n do Cpu.step_instr b (b.icache.(b.pc) land lnot (1 lsl 61)) done;
  assert (regs.(0)=b.pc && regs.(1)=b.ap && regs.(2)=b.fp && regs.(3)=b.hi.(1));
  assert (regs.(4)=b.tlen);
  for i=0 to b.tlen-1 do assert (raw_get a.trace i = raw_get b.trace i) done;
  Array.iteri (fun i mem ->
      if i<>1 then assert (a.hi.(i)=b.hi.(i));
      for j=0 to slen mem-1 do assert (Felt.equal (sget mem j) (sget b.segs.(i) j)) done;
      if i>=2 then Bytes.iteri (fun off bit ->
          if Bytes.get a.watched.(i) off <> bit then begin
            (* The ordinary kernel marks the indirect operand of an attempted
               instruction before scalar deduction handles it. *)
            assert (n<7 && bit='\000' && Bytes.get a.watched.(i) off='\001');
            let op=b.icache.(b.pc) in
            assert ((op lsr 50) land 3=0);
            let at = b.ap + ((op lsr 16) land 65535) - 32768 in
            let pointer=sget b.segs.(1) at in
            assert (Felt.is_reloc pointer && Felt.rseg pointer=i &&
                    Felt.roff pointer + ((op lsr 32) land 65535) - 32768=off)
          end) b.watched.(i)) a.segs;
  n

let () =
  limbs ();
  let open Segment in
  List.iter (fun tracing ->
      List.iter (fun x ->
          assert (compare tracing x ignore = 7);
          List.iter (fun at -> ignore (compare tracing x (fun vm ->
              vm.icache.(at) <- vm.icache.(at) lor (1 lsl 61)))) [1;2;3;4;6;7];
          ignore (compare tracing x (fun vm -> sset vm.segs.(4) 4 Felt.empty));
          ignore (compare tracing x (fun vm -> sset vm.segs.(3) 2 Felt.one));
          ignore (compare tracing x (fun vm -> sset vm.segs.(1) (vm.ap+3) (Felt.small 17))))
        [Z.zero; Z.of_int 42; Z.shift_left Z.one 62; Z.pred (Z.shift_left Z.one 63)]) [false;true]

(* Exercise the real registered hint, including the read-all-inputs boundary
   and the ordinary write-once failure order. *)
let () =
  let open Program in
  let reference off = {r_expr=Deref (Add (Reg_fp, Int (Z.of_int off)));
                       r_group=0;r_offset=0} in
  let prog={data=[||];builtins=[];main=None;start=None;end_=None;hints=[];
            references=Array.init 3 reference;identifiers=Hashtbl.create 0} in
  let call vm =
    let matched=ref false in
    Blake2s.register (fun code compile ->
        if code=Hint_codes.blake2s_unpack_felts then begin
          let hint={code;scopes=["test"];h_group=0;h_offset=0;ref_ids=[
              "test.packed_values_len",0;"test.packed_values",1;"test.unpacked_u32s",2]} in
          matched:=true;
          compile (Hintrt.make_ctx prog (Hintrt.new_scopes ()) hint) vm
        end);
    assert !matched in
  let mk_vm () =
    let vm=Vm.create ~trace:false in
    for _=0 to 3 do ignore (Vm.add_segment vm) done;
    vm.fp<-3;
    Vm.write vm 1 3 (Felt.small 2); Vm.write vm 1 4 (Felt.reloc 2 0);
    Vm.write vm 1 5 (Felt.reloc 3 0); Vm.write vm 2 0 (Felt.small 9);
    vm in
  let reject vm =
    match call vm with () -> assert false | exception Errors.Vm_error _ -> () in
  let missing=mk_vm () in
  reject missing;
  assert (Vm.get missing 3 0=Felt.empty);
  Vm.write missing 2 1 (Felt.reloc 2 0);
  reject missing;
  assert (Vm.get missing 3 0=Felt.empty);
  let conflict=mk_vm () in
  Vm.write conflict 2 1 Felt.one; Vm.write conflict 3 1 (Felt.small 5);
  reject conflict;
  assert (Vm.get conflict 3 0=Felt.zero && Vm.get conflict 3 1=Felt.small 5 &&
          Vm.get conflict 3 2=Felt.empty)
