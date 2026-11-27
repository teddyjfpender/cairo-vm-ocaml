open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let base = Vm.add_segment vm in
  let builtin : Builtin.builtin = { kind = Builtin.Pedersen; base; stop_ptr = 0; cache = [||] } in
  let x () = Felt.of_z (Z.shift_left Z.one 210) in
  let put i a b = Vm.write vm base (3*i) a; Vm.write vm base (3*i+1) b in
  let deduce i = Deduce.deduce_builtin vm builtin base (3*i+2) in
  put 0 (x ()) Felt.one; put 1 (x ()) Felt.one;
  Vm.write vm base 2 Felt.zero;
  (* A program-written previous output is not an authoritative cached hash. *)
  let second = deduce 1 in
  assert (not (Felt.equal second Felt.zero));
  assert (Felt.equal second (deduce 0));
  put 2 (x ()) Felt.one;
  let cursor = !Felt.pool_n in
  assert (deduce 2 = second && !Felt.pool_n = cursor);
  put 3 (x ()) Felt.zero;
  assert (not (Felt.equal (deduce 3) second));
  put 4 Felt.one Felt.zero;
  assert (not (Felt.equal (deduce 4) (deduce 3)))

(* PIE verification can overlap execution. Only complete inputs from the
   immutable snapshot may populate the deduction cache. *)
let () =
  let verify ~corrupt =
    let vm = Vm.create ~trace:false in
    let base = Vm.add_segment vm in
    let b : Builtin.builtin = {kind = Pedersen; base; stop_ptr = 0; cache = [||]} in
    vm.builtins <- [b];
    vm.seg_flag.(base) <- Builtin.flag_of Pedersen;
    vm.seg_builtin.(base) <- Some b;
    let x = Felt.of_z (Z.shift_left Z.one 220) in
    let hash = Felt.pedersen x Felt.one in
    let count = 2049 and incomplete = 33 in
    for i = 0 to count - 1 do
      Vm.write vm base (3*i) x;
      if i <> incomplete then Vm.write vm base (3*i+1) Felt.one;
      Vm.write vm base (3*i+2) (if i = count-1 && corrupt then Felt.zero else hash)
    done;
    Resources.with_preverified_pedersen vm (fun () ->
        Vm.write vm base (3*incomplete+1) Felt.one;
        Gc.full_major ());
    assert (Deduce.cache_get b (3*incomplete+2) = Felt.empty);
    if corrupt then begin
      assert (Deduce.cache_get b 2 = Felt.empty);
      match Resources.verify_auto_deductions vm with
      | () -> failwith "invalid Pedersen output accepted"
      | exception Errors.Vm_error _ -> ()
    end else Resources.verify_auto_deductions vm
  in
  verify ~corrupt:false;
  verify ~corrupt:true
