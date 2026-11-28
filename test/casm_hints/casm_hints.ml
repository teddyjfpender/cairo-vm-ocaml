open Cairovm
module U = Yojson.Safe.Util

let check vector =
  let vm = Vm.create ~trace:false in
  for _ = 0 to 2 do ignore (Vm.add_segment vm) done;
  Vm.write vm 1 0 (Felt.reloc 2 0);
  let scopes = Hintrt.new_scopes () in
  let rng = lazy (failwith "unexpected random hint") in
  let syscall _ _ = failwith "unexpected syscall" in
  List.iter (fun hint -> Casm_hints.compile ~rng ~syscall scopes hint vm)
    (U.to_list (U.member "hints" vector));
  let compare segment start name =
    List.iteri (fun i value ->
        let expected = Z.of_string (U.to_string value) in
        assert (Z.equal expected (Felt.to_z (Vm.get vm segment (start + i)))))
      (U.to_list (U.member name vector)) in
  compare 1 1 "stack";
  compare 2 0 "range_check"

let () = List.iter check (U.to_list (Yojson.Safe.from_file "vectors.json"))
