open Cairovm

let () =
  let open Pie_zip_limits in
  assert (fits_field 0xffff_fffe);
  assert (not (fits_field 0xffff_ffff));
  assert (not (fits_field (-1)));
  assert (fits_production_memory (0xffff_ffff - (64 lsl 20) - 1));
  assert (not (fits_production_memory (0xffff_ffff - (64 lsl 20))));
  assert (not (fits_production_memory 0xffff_fffe))

exception Stop_writer

let () =
  let output = Filename.temp_file "oxcairo-atomic-" ".zip" in
  Fun.protect ~finally:(fun () -> Sys.remove output) (fun () ->
    Out_channel.with_open_bin output (fun oc -> output_string oc "previous archive");
    let fail_after_input sink =
      sink (Bytes.make 40 'x') 40;
      raise Stop_writer in
    (match Pie_zip.write ~profile:Os_host_production ~level:0 output ["memory.bin", fail_after_input] with
     | () -> failwith "writer ignored member exception"
     | exception Stop_writer -> ());
    assert (In_channel.with_open_bin output In_channel.input_all = "previous archive"))
