open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let base = Vm.add_segment vm in
  let builtin : Builtin.builtin = { kind = Builtin.Pedersen; base; included = true; stop_ptr = 0; cache = [||] } in
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
