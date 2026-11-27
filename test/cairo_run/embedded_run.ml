open Cairovm

(* A CairoZero program consisting of a single ret at entrypoint "custom". *)
let image =
  `Assoc [
    "prime", `String (Z.to_string Felt.p);
    "data", `List [`String "0x208b7fff7fff7ffe"];
    "builtins", `List [];
    "identifiers", `Assoc ["__main__.custom", `Assoc ["type", `String "function"; "pc", `Int 0]];
  ]

let () =
  let config = { Cairo_run.default_config with entrypoint = "custom"; trace = true } in
  let program = Program.load_json image in
  let first = Cairo_run.run ~config program in
  let second = Cairo_run.run ~config ~fill_holes:true program in
  List.iter (fun run ->
    assert (run.Runner.vm.steps = 1);
    assert (run.vm.tlen = 1);
    assert (Runner.output_lines run = [])) [first; second];
  assert (first.vm != second.vm);
  match Cairo_run.run program with
  | exception Errors.Vm_error _ -> ()
  | _ -> failwith "missing entrypoint accepted"
