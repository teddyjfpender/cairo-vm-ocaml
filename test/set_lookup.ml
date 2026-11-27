open Cairovm

let () =
  let make_vm () =
    let vm = Vm.create ~trace:false in
    ignore (Vm.add_segment vm);
    vm
  in
  let vm = make_vm () in
  let small = Felt.small and base = Felt.reloc 0 0 in
  let cache = ref None in
  let find vm base total words = Hints.find_set_element cache vm base total (Array.of_list words) in
  let write i v = Vm.write vm 0 i v in
  for i = 0 to 47 do
    write (2 * i) (small (i mod 4));
    if i <> 40 then write (2 * i + 1) (small i)
  done;
  (* An unrelated lookup indexes the first word of a row with a hole. *)
  assert (find vm base 96 [small 5; small 0] = -1);
  assert (find vm base 96 [small 0; small 4] = 4);
  assert (find vm base 72 [small 1; small 41] = -1);
  assert (find vm base 96 [small 1; small 41] = 41);
  (match find vm base 96 [small 0; small 44] with
  | exception Vm.Vm_error msg -> assert (msg = "Unknown memory cell 0:81")
  | _ -> failwith "expected the earlier missing suffix to be read");
  write 81 (small 0);
  assert (find vm base 96 [small 0; small 44] = 44);
  (* Duplicates must return the first index. Distinct big-felt slots can be equal. *)
  let big () = Felt.of_z (Z.shift_left Z.one 180) in
  write 96 (big ()); write 97 (small 3);
  write 98 (big ()); write 99 (small 3);
  assert (find vm base 100 [big (); small 3] = 48);
  assert (find vm base 96 [big (); small 3] = -1);
  assert (find vm (Felt.reloc 0 2) 98 [big (); small 3] = 47);
  assert (find vm base 100 [big ()] = 96);
  (* Reusing a compiled hint on a different VM cannot reuse the old range. *)
  let other = make_vm () in
  for i = 0 to 99 do Vm.write other 0 i (small i) done;
  assert (find other base 100 [small 97] = 97);
  assert (find other base 100 [big ()] = -1)
