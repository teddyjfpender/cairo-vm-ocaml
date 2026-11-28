open Cairovm

let () =
  let prog = Program.load_file Sys.argv.(1) in
  let cfg = Runner.{layout="all_cairo_stwo"; trace=true; secure_run=false;
                    allow_missing_builtins=true; entrypoint="main"} in
  let runner = match Array.to_list Sys.argv with
    | [_; _; _] -> Runner.initialize ~proof:true cfg prog
    | [_; _; _; "--bootloader"; path] -> Bootloader.initialize ~proof:true ~path cfg prog
    | [_; _; _; "--os"; path] -> Os_hints.initialize ~proof:true ~path cfg prog
    | _ -> invalid_arg "PROGRAM SNAPSHOT [--bootloader INPUT | --os INPUT]" in
  Runner.run_until_end runner;
  Finalize.end_run ~disable_trace_padding:true ~fill_holes:true runner ~secure:false ~allow_missing:true;
  let vm = runner.vm in
  Out_channel.with_open_bin Sys.argv.(2) (fun oc ->
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
