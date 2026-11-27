open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let seg = Vm.add_segment vm and base = Felt.reloc 0 0 in
  let big () = Felt.of_z (Z.shift_left Z.one 160) in
  let put i x = Vm.write vm seg i x in
  let cache = ref None in
  let search n v = Find_element.lookup cache vm base 1 n v in
  List.iteri put [big (); Felt.small 1; big (); base];
  assert (search 4 base = 3);
  assert (search 4 base = 3);
  assert (search 3 (big ()) = 0);
  let error expected f = match f () with
    | exception Vm.Vm_error msg -> assert (msg = expected)
    | _ -> failwith "expected lookup failure" in
  error "Key 0:0 was not found." (fun () -> search 3 base);
  error "Unknown memory cell 0:4" (fun () -> search 6 Felt.zero);
  put 4 Felt.zero;
  assert (search 6 Felt.zero = 4);
  assert (Find_element.lookup cache vm (Felt.reloc 0 1) 1 3 base = 2);
  assert (Find_element.lookup cache vm base 2 3 Felt.zero = 2);
  error "Key 0 was not found." (fun () -> search 0 Felt.zero);
  assert (search 5 Felt.zero = 4);
  let other = Vm.create ~trace:false in
  ignore (Vm.add_segment other);
  Vm.write other 0 0 Felt.zero;
  assert (Find_element.lookup cache other base 1 1 Felt.zero = 0)
