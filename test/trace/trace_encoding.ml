open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  vm.trace <- Segment.seg_make 4;
  let max_reg = (1 lsl 23) - 1 in
  let rows = [
    (0, 0, 0, 0); (0, 65535, max_reg, max_reg);
    (0, 65536, 42, 41); (0, 0, max_reg + 1, 1);
    (0, 0, 1, max_reg + 1); (2, 19, 61, 58); (0, 7, 11, 5);
    (1023, 262143, 16777215, 16776704); (1024, 2, 3, 3); (1, 262144, 3, 3);
    (1, 3, 16777216, 16777216); (1, 3, 513, 1); (1, 3, 1, 3);
  ] in
  List.iter (fun (seg, pc, ap, fp) -> Cpu.record_trace vm seg pc ap fp) rows;
  assert (vm.tlen = 6 + 7 * 3);
  let cursor = ref 0 in
  List.iter (fun expected ->
      let next, seg, pc, ap, fp = Resources.trace_entry vm.trace !cursor in
      assert ((seg, pc, ap, fp) = expected);
      cursor := next) rows;
  let bases = Array.init 1025 (fun i -> 1 + i * 70200) in
  let path = Filename.temp_file "cairo-trace" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Artifacts.c_write_trace path vm.trace vm.tlen bases;
    let raw = In_channel.with_open_bin path In_channel.input_all in
    assert (String.length raw = List.length rows * 24);
    List.iteri (fun i (seg, pc, ap, fp) ->
      List.iteri (fun j expected ->
        assert (String.get_int64_le raw (24 * i + 8 * j) = Int64.of_int expected))
        [bases.(1) + ap; bases.(1) + fp; bases.(seg) + pc]) rows)

let () =
  (* Two relative jumps reach the proof program's end loop in three steps. *)
  let jump = Z.of_string "0x10780017fff7fff" in
  let program = {Program.data=[|jump; Z.of_int 2; jump; Z.of_int 2; jump; Z.zero|];
                 builtins=[]; main=Some 0; start=Some 0; end_=Some 4;
                 hints=[]; references=[||]; identifiers=Hashtbl.create 0} in
  let runner layout =
    Runner.initialize ~proof:true {Cairo_run.default_config with layout} program in
  let run disable_trace_padding =
    let r = runner "plain" in
    Runner.run_until_end r;
    Finalize.end_run ~disable_trace_padding r ~secure:true ~allow_missing:false;
    r in
  let unpadded = run true and padded = run false in
  assert (unpadded.vm.steps = 3 && unpadded.vm.tlen = 3);
  assert (padded.vm.steps >= 4 && padded.vm.steps land (padded.vm.steps - 1) = 0);
  for i = 0 to 2 do
    assert (Resources.trace_entry unpadded.vm.trace i = Resources.trace_entry padded.vm.trace i)
  done;
  let r = runner "small" in
  let b = List.find (fun b -> b.Builtin.kind = Builtin.Range_check) r.vm.builtins in
  let capacities () = Resources.used_and_allocated ~disable_trace_padding:true r b in
  assert (capacities () = (0,0));
  Vm.write r.vm b.base 0 Felt.zero;
  assert (capacities () = (1,16));
  Vm.write r.vm b.base 16 Felt.zero;
  assert (capacities () = (17,32))

let () =
  let jump = Z.of_string "0x10780017fff7fff" in
  let compare ~hinted ~self_jump =
    let offset = if self_jump then Z.zero else Z.of_int 2 in
    let program = {Program.data=[|jump; offset; jump; Z.of_int (-2)|];
                   builtins=[]; main=Some 0; start=Some 0; end_=Some 0;
                   hints=[]; references=[||]; identifiers=Hashtbl.create 0} in
    let create () =
      let r = Runner.initialize ~proof:true {Cairo_run.default_config with layout="plain"} program in
      let hits = ref 0 in
      let r = if hinted then {r with hints=[|[|(fun _ -> incr hits)|]|]} else r in
      Runner.run_for_steps r 34;
      r, hits in
    let ordinary, expected_hits = create () and padded, hits = create () in
    Runner.run_for_steps ordinary 30;
    Resources.run_until_next_power_of_2 padded;
    assert (!hits = !expected_hits);
    assert (padded.vm.steps = 64 && padded.vm.pc = ordinary.vm.pc);
    assert (padded.vm.tlen = ordinary.vm.tlen && padded.vm.last_trace = ordinary.vm.last_trace);
    for i = 0 to ordinary.vm.tlen - 1 do
      assert (Segment.raw_get ordinary.vm.trace i = Segment.raw_get padded.vm.trace i)
    done;
    assert (Resources.perm_range_check_limits padded = Resources.perm_range_check_limits ordinary);
    assert (Resources.memory_holes padded = Resources.memory_holes ordinary);
    assert (padded.acc.count = ordinary.acc.count && padded.acc.bits = ordinary.acc.bits)
  in
  compare ~hinted:false ~self_jump:true;
  compare ~hinted:true ~self_jump:true;
  compare ~hinted:false ~self_jump:false;
  (* A large AP uses a full three-word trace entry. Include the preceding
     packed entry and exercise growth and a final partial doubling. *)
  let vm = Vm.create ~trace:true in
  Cpu.record_trace vm 0 1 2 2;
  Cpu.record_trace vm 0 2 (1 lsl 25) 2;
  let trace, used = Segment.repeat_trace_tail vm.trace ~first:vm.last_trace ~used:vm.tlen ~copies:1347 in
  assert (used = 1 + 3 * 1348);
  for i = 0 to 1347 do
    let pos = 1 + 3 * i in
    assert (Resources.trace_entry trace pos = (pos + 3, 0, 2, 1 lsl 25, 2))
  done

let () =
  let jump = Z.of_string "0x10780017fff7fff" in
  let program = {Program.data=[|jump; Z.zero|]; builtins=[]; main=Some 0;
                 start=Some 0; end_=Some 0; hints=[]; references=[||];
                 identifiers=Hashtbl.create 0} in
  let check cached =
    let r = Runner.initialize ~proof:false {Cairo_run.default_config with trace=true} program in
    let vm = r.vm in
    let code = Vm.add_segment vm in
    Vm.write vm code 0 (Felt.of_z jump);
    Vm.write vm code 1 Felt.zero;
    Vm.write vm code 6 Felt.one;
    Vm.write vm 1 12 Felt.one;
    let decoded = Instruction.decode_word jump in
    vm.icache <- [|decoded; 0|];
    if cached then begin
      let page = Array.make 1024 0 in
      page.(0) <- decoded;
      Hashtbl.add vm.code_pages (code,0) page
    end;
    let steps = 250_007 in
    for i = 0 to steps - 1 do
      let seg = if i mod 5 = 0 then code else 0 in
      let fp = 2 + i mod 7 in
      Cpu.record_trace vm seg 0 fp fp
    done;
    vm.steps <- steps;
    let published = Resources.pie_memory_holes r in
    assert (published > 0 && published = Resources.memory_holes r)
  in
  check true;
  check false
