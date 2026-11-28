(* Immutable code shared by repeated executions. Wide field values in the
   template use offsets into a private limb buffer, never the live VM pool. *)
module BA = Bigarray.Array1

type t = {
  source : Z.t array;
  words : int array;
  limbs : Felt.pool;
  decoded : int array;
}

let prepare (program : Program.t) =
  Felt.with_temporary_slots (fun () ->
      let first = !Felt.pool_n in
      let memo = Hashtbl.create 256 in
      let source = Array.copy program.data in
      let words = Array.make (Array.length source) 0 and decoded = Array.make (Array.length source) 0 in
      Array.iteri (fun i z ->
          let word, instruction = match Hashtbl.find_opt memo z with
            | Some pair -> pair
            | None ->
                let value = Felt.of_z z in
                let code = (value :> int) in
                let word = if code land 3 = 3 then code - (first lsl 2) else code in
                let instruction = try
                    let d = Instruction.decode_word (Felt.to_z value) in
                    if d land Instruction.ext_mask = 0 then d else 0
                  with Instruction.Generic_instruction | Errors.Vm_error _ -> 0 in
                let pair = word,instruction in
                Hashtbl.add memo z pair; pair in
          words.(i) <- word; decoded.(i) <- instruction) source;
      let bytes = (!Felt.pool_n-first)*32 in
      let limbs = BA.create Bigarray.char Bigarray.c_layout bytes in
      BA.blit (BA.sub Felt.pool (first*32) bytes) limbs;
      {source;words;limbs;decoded})

let load image (prog : Program.t) (vm : Vm.vm) =
  if vm.nsegs = 0 || vm.hi.(0) <> 0 || vm.seg_flag.(0) <> Builtin.k_plain then
    invalid_arg "Program image needs an empty plain program segment";
  if image.source <> prog.data then invalid_arg "Program image does not match program data";
  let bytes = BA.dim image.limbs and first = !Felt.pool_n in
  Felt.reserve (bytes / 32);
  BA.blit image.limbs (BA.sub Felt.pool (first*32) bytes);
  Felt.pool_n := first + bytes / 32;
  let n = Array.length image.words in
  if n > Segment.slen vm.segs.(0) then Vm.grow_seg vm 0 (n-1);
  let cells = vm.segs.(0) in
  Array.iteri (fun i v -> Segment.raw_set cells i (if v land 3 = 3 then v + (first lsl 2) else v)) image.words;
  vm.hi.(0) <- n;
  vm.icache <- Array.copy image.decoded;
  List.iter (fun (pc,hints) ->
      if hints <> [] && pc >= 0 && pc < n && vm.icache.(pc) <> 0 then
        vm.icache.(pc) <- vm.icache.(pc) lor (1 lsl Instruction.ext_shift)) prog.hints
