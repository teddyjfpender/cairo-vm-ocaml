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
