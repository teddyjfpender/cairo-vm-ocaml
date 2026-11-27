open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  let seg = Vm.add_segment vm in
  let base = Felt.reloc seg 0 and small = Felt.small in
  let cursor = ref None in
  let query n key = Hints.search_lower cursor vm base 1 n key in
  List.iteri (fun i v -> Vm.write vm seg i (small v)) [1; 5; 2; 5; 9];
  (* Unsorted rows, duplicates, reversed queries, empty and shrinking ranges. *)
  assert (query 5 (small 3) = 1);
  assert (query 5 (small 5) = 1);
  assert (query 5 (small 6) = 4);
  assert (query 2 (small 7) = 2);
  assert (query 0 (small 9) = 0);
  assert (query 5 (small 4) = 1);
  assert (query 6 (small 9) = 4);
  (match query 6 (small 10) with
   | exception Vm.Vm_error msg -> assert (msg = "Unknown memory cell 0:5")
   | _ -> failwith "missing row was skipped");
  let big = Felt.of_z (Z.shift_left Z.one 180) in
  Vm.write vm seg 5 big;
  Vm.write vm seg 6 base;
  assert (query 7 big = 5);
  assert (query 7 (small (-1)) = 6);
  assert (Hints.search_lower cursor vm base 2 4 (small 5) = 2);
  assert (Hints.search_lower cursor vm (Felt.reloc seg 1) 1 4 (small 5) = 0);
  let other = Vm.create ~trace:false in
  ignore (Vm.add_segment other);
  Vm.write other seg 0 (small 10);
  assert (query 5 (small 9) = 4);
  assert (Hints.search_lower cursor other base 1 1 (small 10) = 0)
