(* End of run: return values, segment finalization and the secure-run
   checks (cairo-vm end_run / read_return_values / verify_secure_runner). *)

open Errors
open Builtin
open Vm
open Deduce
open Runner
open Resources
open Artifacts

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
            if v = Felt.empty || not (Felt.is_felt v) then fail "Expected integer at address 1:%d" !pointer;
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
    r.vm.builtins;
  if r.zero_seg >= 0 then begin
    Hashtbl.replace r.seg_sizes r.zero_seg r.zero_size;
    Hashtbl.replace r.public_offsets r.zero_seg []
  end

let verify_secure_runner r =
  let vm = r.vm in
  List.iter
    (fun b ->
      let n = used_size vm b.base in
      (* builtins without a stop pointer (proof-mode extras) are skipped *)
      if b.stop_ptr >= 0 && n >= b.stop_ptr + 1 then fail "Out of bounds access to builtin segment %s" (bname b.kind))
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
              if read vm b.base i <> Felt.empty then incr filled
            done;
            let ninst = ((n - 1) / cpi) + 1 in
            if ninst > !filled / nin then fail "Missing memory cells for builtin %s" (bname k);
            for i = 0 to ninst - 1 do
              for j = 0 to nin - 1 do
                if read vm b.base ((cpi * i) + j) = Felt.empty then
                  fail "Missing memory cells for builtin %s at offset %d" (bname k) ((cpi * i) + j)
              done;
              for j = nin to cpi - 1 do
                let off = (cpi * i) + j in
                if read vm b.base off = Felt.empty && is_deducing vm.seg_flag.(b.base) then
                  ignore (deduce_builtin vm b b.base off)
              done
            done
          end)
    vm.builtins;
  if r.proof then begin
    (* canonical proof mode: [initial_fp - 2] must be the final fp *)
    let v = read vm 1 (r.initial_fp - 2) in
    if v = Felt.empty then fail "Missing return fp at 1:%d" (r.initial_fp - 2);
    if Felt.is_reloc v then begin
      if v <> Felt.reloc 1 vm.fp then
        fail "Return fp %d:%d does not match final fp 1:%d" (Felt.rseg v) (Felt.roff v) vm.fp
    end
    else if not (Felt.equal v (Felt.of_int vm.fp)) then
      fail "Return fp %s does not match final fp 1:%d" (value_to_string v) vm.fp
  end

let end_run ?(fill_holes=false) r ~secure ~allow_missing =
  relocate_temp_memory r.vm;
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
