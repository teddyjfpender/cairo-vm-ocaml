open Cairovm

let runner builtins =
  let prog = {
    Program.data = [||]; builtins; main = Some 0; start = None; end_ = None; hints = [];
    references = [||]; identifiers = Hashtbl.create 1
  } in
  Runner.initialize { Runner.layout = "all_cairo"; trace = false; secure_run = true;
                      allow_missing_builtins = false; entrypoint = "main" } prog

let check r expected =
  let lines = ref [] in
  Artifacts.iter_output_lines r (fun s -> lines := s :: !lines);
  assert (List.rev !lines = expected);
  assert (Artifacts.output_lines r = expected)

let () =
  check (runner []) [];
  let r = runner ["output"] in
  check r [];
  let b = List.hd r.vm.builtins in
  let put = Vm.write r.vm b.base in
  let wide = Z.shift_left Z.one 128 in
  put 0 (Felt.small (-7));
  put 2 (Felt.reloc 0 123);
  put 3 (Felt.of_z wide);
  put 4 (Felt.of_z (Z.neg wide));
  check r ["-7"; "<missing>"; "0:123"; Z.to_string wide; Z.to_string (Z.neg wide)]
