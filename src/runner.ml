(* Execution-mode runner, mirroring cairo-vm v3.2.0's cairo_run for non-proof mode. *)

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
  | _ -> None

type config = {
  layout : string;
  trace : bool;
  secure_run : bool;
  allow_missing_builtins : bool;
  entrypoint : string;
}

type t = {
  vm : vm;
  prog : Program.t;
  end_seg : int;
  hints : (vm -> unit) array array;
  prog_builtins : bkind list;
  scopes : Hintrt.scopes;
}

let rec is_subsequence xs ys =
  match (xs, ys) with
  | [], _ -> true
  | _, [] -> false
  | x :: xs', y :: ys' -> if x = y then is_subsequence xs' ys' else is_subsequence xs ys'

let initialize (cfg : config) (prog : Program.t) : t =
  let prog_builtins =
    List.map
      (fun n -> match bkind_of_name n with Some k -> k | None -> fail "Unknown builtin %s" n)
      prog.builtins
  in
  if not (is_subsequence prog_builtins all_builtins) then fail "Disordered builtins";
  let layout = match layout_builtins cfg.layout with Some l -> l | None -> fail "Unsupported layout %s" cfg.layout in
  List.iter
    (fun b ->
      if (not (List.mem b layout)) && not cfg.allow_missing_builtins then
        fail "Program uses builtin %s, which is not present in layout %s" (bname b) cfg.layout)
    prog_builtins;
  Builtins_ext.reset ();
  Builtins_ext.install ();
  Opcode_ext.install ();
  let vm = create ~trace:cfg.trace in
  let s0 = add_segment vm in
  let s1 = add_segment vm in
  assert (s0 = 0 && s1 = 1);
  let active = List.filter (fun b -> List.mem b prog_builtins) layout in
  let builtins =
    List.map
      (fun k ->
        let seg = add_segment vm in
        let b = { kind = k; base = seg; included = true; stop_ptr = 0; cache = [||] } in
        vm.seg_builtin.(seg) <- Some b;
        vm.seg_flag.(seg) <-
          (match k with
          | Range_check -> k_rc
          | Range_check96 -> k_rc96
          | Bitwise -> k_bitwise
          | Pedersen -> k_pedersen
          | Poseidon -> k_poseidon
          | Keccak -> k_keccak
          | Ec_op -> k_ec_op
          | Ecdsa -> k_ecdsa
          | _ -> k_plain);
        b)
      active
  in
  vm.builtins <- builtins;
  let return_fp = add_segment vm in
  let end_seg = add_segment vm in
  (* cairo-vm creates the mod builtins' shared zero segment after the
     entrypoint segments *)
  (match List.filter (fun b -> b.kind = Add_mod || b.kind = Mul_mod) builtins with
  | [] -> ()
  | mods -> ignore (Builtins_ext.add_zero_segment vm mods));
  let entry =
    let name = cfg.entrypoint in
    let full = "__main__." ^ name in
    match Hashtbl.find_opt prog.identifiers full with
    | Some { Program.i_pc = Some pc; _ } -> pc
    | _ -> (
        match (name, prog.main) with
        | "main", Some pc -> pc
        | _ -> fail "Entrypoint %s not found" name)
  in
  (* program image *)
  Array.iteri (fun i z -> write vm 0 i (Felt.of_z z)) prog.data;
  (* stack *)
  let stack =
    List.map
      (fun k ->
        match List.find_opt (fun b -> b.kind = k) builtins with
        | Some b -> Felt.reloc b.base 0
        | None -> Felt.zero)
      prog_builtins
    @ [ Felt.reloc return_fp 0; Felt.reloc end_seg 0 ]
  in
  List.iteri (fun i v -> write vm 1 i v) stack;
  let n = List.length stack in
  vm.pc_seg <- 0;
  vm.pc <- entry;
  vm.ap <- n;
  vm.fp <- n;
  let scopes = Hintrt.new_scopes () in
  Hints_registry.init ();
  let hints = Array.make (Array.length prog.data) [||] in
  List.iter
    (fun (pc, hs) ->
      if pc < Array.length hints then
        hints.(pc) <- Array.of_list (List.map (fun h -> Hints.compile prog scopes h) hs))
    prog.hints;
  { vm; prog; end_seg; hints; prog_builtins; scopes }

let run_until_end r = run r.vm r.hints r.end_seg

(* ---- end of run ---- *)

external verified_bitwise : bytes -> seg -> int -> bool = "cvm_verify_bitwise" [@@noalloc]

external verified_pedersen : bytes -> seg -> int -> int array -> bool = "cvm_verify_pedersen" [@@noalloc]

let verify_auto_deductions ?(fill_holes=false) vm =
  List.iter
    (fun b ->
      if is_deducing vm.seg_flag.(b.base) &&
         (fill_holes || not (match b.kind with
          | Bitwise -> verified_bitwise !Felt.pool vm.segs.(b.base) (used_size vm b.base)
          | Pedersen -> verified_pedersen !Felt.pool vm.segs.(b.base) (used_size vm b.base) b.cache
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
          pointer := max 0 (!pointer - 1))
    (List.rev r.prog_builtins)

let check_no_temp_values vm =
  for s = 0 to vm.nsegs - 1 do
    let a = vm.segs.(s) in
    for i = 0 to min (used_size vm s) (slen a) - 1 do
      let v = sget a i in
      if Felt.is_reloc v && Felt.rseg v < 0 then
        fail "Invalid memory value at %d:%d: temporary address %d:%d" s i (Felt.rseg v) (Felt.roff v)
    done
  done

let verify_secure_runner r =
  let vm = r.vm in
  List.iter
    (fun b ->
      let n = used_size vm b.base in
      if n >= b.stop_ptr + 1 then fail "Out of bounds access to builtin segment %s" (bname b.kind))
    vm.builtins;
  if used_size vm 0 > Array.length r.prog.data then fail "Out of bounds access to program segment";
  (* every temporary address must have been relocated to a real one *)
  if vm.ntsegs > 0 then check_no_temp_values vm;
  (* builtin security checks: inputs of every instance must be present *)
  List.iter
    (fun b ->
      match b.kind with
      | Output -> ()
      | k ->
          if k = Add_mod || k = Mul_mod then Builtins_ext.security_check vm b;
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
                if read vm b.base off = 0 && is_deducing vm.seg_flag.(b.base) then
                  ignore (deduce_builtin vm b b.base off)
              done
            done
          end)
    vm.builtins

let end_run ?(fill_holes=false) r ~secure ~allow_missing =
  relocate_temp_memory r.vm;
  if not (Hintrt.only_main_scope r.scopes) then fail "Every enter_scope() requires a corresponding exit_scope()";
  verify_auto_deductions ~fill_holes r.vm;
  read_return_values r ~allow_missing;
  if secure then verify_secure_runner r

(* ---- relocation & outputs ---- *)

let relocation_table vm =
  let t = Array.make (vm.nsegs + 1) 1 in
  for s = 0 to vm.nsegs - 1 do
    t.(s + 1) <- t.(s) + used_size vm s
  done;
  t

external c_write_trace : string -> seg -> int -> int array -> unit = "cvm_write_trace"

external c_write_memory : string -> seg array -> int array -> int array -> int -> bytes -> unit
  = "cvm_write_memory_byte" "cvm_write_memory"

let write_trace r path =
  let vm = r.vm in
  c_write_trace path vm.trace vm.tlen (relocation_table vm)

let write_memory r path =
  let vm = r.vm in
  (* relocate_value rejects temporary segments (TemporarySegmentInRelocation) *)
  if vm.had_temp then check_no_temp_values vm;
  let sizes = Array.init vm.nsegs (used_size vm) in
  c_write_memory path vm.segs sizes (relocation_table vm) vm.nsegs !Felt.pool

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
