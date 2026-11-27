open Cairovm

let () =
  let vm = Vm.create ~trace:false in
  vm.trace <- Segment.seg_make 4;
  let max_reg = (1 lsl 23) - 1 in
  let rows = [
    (0, 0, 0, 0); (0, 65535, max_reg, max_reg);
    (0, 65536, 42, 41); (0, 0, max_reg + 1, 1);
    (0, 0, 1, max_reg + 1); (2, 19, 61, 58); (0, 7, 11, 5);
  ] in
  List.iter (fun (seg, pc, ap, fp) -> Cpu.record_trace vm seg pc ap fp) rows;
  assert (vm.tlen = 3 + 4 * 3);
  let bases = [| 1; 70200; 9000000 |] in
  let path = Filename.temp_file "cairo-trace" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Runner.c_write_trace path vm.trace vm.tlen bases;
    let raw = In_channel.with_open_bin path In_channel.input_all in
    assert (String.length raw = List.length rows * 24);
    List.iteri (fun i (seg, pc, ap, fp) ->
      List.iteri (fun j expected ->
        assert (String.get_int64_le raw (24 * i + 8 * j) = Int64.of_int expected))
        [bases.(1) + ap; bases.(1) + fp; bases.(seg) + pc]) rows)
