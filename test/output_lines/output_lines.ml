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

let () =
  let r = runner ["output"] in
  let b = List.hd r.vm.builtins in
  let half = Z.shift_right Felt.p 1 in
  let cases = Array.of_list [
    Felt.zero; Felt.one; Felt.small (-1); Felt.reloc 0 0; Felt.reloc (-1) 19;
    Felt.of_z half; Felt.of_z (Z.succ half); Felt.of_z (Z.pred half);
    Felt.of_z (Z.pred (Z.shift_left Z.one 64)); Felt.of_z (Z.shift_left Z.one 64);
    Felt.of_z (Z.neg (Z.shift_left Z.one 191))
  ] in
  for i = 0 to 11999 do
    if i mod 13 <> 0 then Vm.write r.vm b.base i cases.(i mod Array.length cases)
  done;
  let expected = String.concat "\n" (Artifacts.output_lines r) ^ "\n" in
  let path = Filename.temp_file "cairo-output" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
      Out_channel.with_open_bin path (fun ch -> Artifacts.write_output ch r);
      assert (In_channel.with_open_bin path In_channel.input_all = expected))
