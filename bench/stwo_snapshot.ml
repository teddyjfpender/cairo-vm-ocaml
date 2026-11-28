open Cairovm

let () =
  let program = ref None and output = ref None and witness = ref None in
  let layout = ref "all_cairo_stwo" and legacy = ref false in
  let set_witness kind path =
    if Option.is_some !witness then raise (Arg.Bad "supply one witness");
    witness := Some (kind, path)
  in
  let args = [
    "--layout", Arg.Set_string layout, "NAME proof-mode layout";
    "--legacy", Arg.Set legacy, "allow Cairo VM 3.2 instructions";
    "--bootloader", Arg.String (set_witness `Bootloader), "FILE bootloader task";
    "--os", Arg.String (set_witness `Os), "FILE Starknet OS input";
    "--virtual-os", Arg.String (set_witness `Virtual), "FILE Virtual OS input";
    "--aggregator", Arg.String (set_witness `Aggregator), "FILE aggregator input";
  ] in
  let positional path = match !program, !output with
    | None, _ -> program := Some path
    | Some _, None -> output := Some path
    | _ -> raise (Arg.Bad "too many paths")
  in
  Arg.parse args positional "stwo_snapshot PROGRAM SNAPSHOT [OPTIONS]";
  let required = function Some p -> p | None -> invalid_arg "expected PROGRAM SNAPSHOT" in
  let prog = Program.load_file (required !program) and destination = required !output in
  let cfg = Runner.{layout= !layout; trace=true; secure_run=false;
                    allow_missing_builtins=true; entrypoint="main"} in
  let runner = match !witness with
    | None -> Runner.initialize ~proof:true cfg prog
    | Some (`Bootloader,path) -> Bootloader.initialize ~proof:true ~path cfg prog
    | Some (`Os,path) -> Os_hints.initialize ~proof:true ~path cfg prog
    | Some (`Virtual,path) -> Os_hints.initialize ~virtual_os:true ~proof:true ~path cfg prog
    | Some (`Aggregator,path) -> Aggregator.initialize ~proof:true ~path cfg prog
  in
  runner.vm.allow_legacy_instructions <- !legacy;
  Runner.run_until_end runner;
  Finalize.end_run ~disable_trace_padding:true ~fill_holes:true runner ~secure:false ~allow_missing:true;
  let vm = runner.vm in
  Out_channel.with_open_bin destination (fun oc ->
    let fmt f = Printf.fprintf oc f in
    let sep i = if i > 0 then output_char oc ',' in
    output_string oc "{\"memory\":[";
    for seg = 0 to vm.nsegs-1 do
      sep seg; output_char oc '[';
      for i = 0 to vm.hi.(seg)-1 do
        sep i;
        let v = Vm.read vm seg i in
        if v = Felt.empty then output_string oc "null"
        else if Felt.is_reloc v then fmt "[%d,%d]" (Felt.rseg v) (Felt.roff v)
        else fmt "\"0x%s\"" (Z.format "%x" (Felt.to_z v))
      done;
      output_char oc ']'
    done;
    output_string oc "],\"trace\":[";
    let cursor = ref 0 in
    while !cursor < vm.tlen do
      sep !cursor;
      let next,seg,pc,ap,fp = Resources.trace_entry vm.trace !cursor in
      fmt "[%d,%d,%d,%d]" seg pc ap fp; cursor := next
    done;
    output_string oc "],\"builtins\":{";
    List.iteri (fun i (b : Builtin.builtin) -> sep i; fmt "\"%d\":\"%s\"" b.base (Builtin.bname b.kind)) vm.builtins;
    output_string oc "},\"public\":{";
    Hashtbl.to_seq runner.public_offsets |> List.of_seq |> List.iteri (fun i (s, offsets) ->
      sep i; fmt "\"%d\":[" s;
      List.iteri (fun k (off,page) -> sep k; fmt "[%d,%d]" off page) offsets; output_char oc ']');
    output_string oc "}}\n");
  Printf.printf "%d executed steps, %d memory segments\n" vm.steps vm.nsegs
