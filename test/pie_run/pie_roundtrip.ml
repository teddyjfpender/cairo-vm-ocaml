open Cairovm

(* main{output_ptr, range_check_ptr}: writes 7 and -5 to the output and 12 to
   the range check segment (cairo-compile 0.14.3). *)
let image =
  `Assoc
    [
      ("prime", `String (Z.to_string Felt.p));
      ( "data",
        `List
          (List.map
             (fun s -> `String s)
             [ "0x480680017fff8000"; "0x7"; "0x400280007ffc7fff"; "0x480680017fff8000";
               "0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffc"; "0x400280017ffc7fff";
               "0x480680017fff8000"; "0xc"; "0x400280007ffd7fff"; "0x482680017ffc8000"; "0x2";
               "0x482680017ffd8000"; "0x1"; "0x208b7fff7fff7ffe" ]) );
      ("builtins", `List [ `String "output"; `String "range_check" ]);
      ("identifiers", `Assoc [ ("__main__.main", `Assoc [ ("type", `String "function"); ("pc", `Int 0) ]) ]);
    ]

let run_pie ?(secure = true) path =
  Pie_run.run ~layout:"small" ~trace:true ~secure ~allow_missing_builtins:false ~fill_holes:false (Pie_file.read path)

let fails f = match f () with exception Errors.Vm_error _ -> true | _ -> false

let () =
  let config = { Cairo_run.default_config with layout = "small"; trace = true } in
  let first = Cairo_run.run ~config (Program.load_json image) in
  let pie = Filename.temp_file "roundtrip" ".pie.zip" and again = Filename.temp_file "roundtrip2" ".pie.zip" in
  Pie.write first ~main:0 ~secure:true ~merge_extra_segments:false pie;
  let res = run_pie pie in
  let r = res.runner in
  assert (r.vm.steps = first.vm.steps);
  assert (Artifacts.output_lines r = [ "7"; "-5" ]);
  assert (Hashtbl.find r.seg_sizes 1 = first.vm.ap);
  (* the re-execution writes the same PIE *)
  Pie.write ~output_pages:res.output_pages ~output_attributes:res.output_attributes r ~main:0 ~secure:true
    ~merge_extra_segments:false again;
  let read p = In_channel.with_open_bin p In_channel.input_all in
  assert (read pie = read again);
  (* a step budget below the recorded one cannot reach the end *)
  let p = Pie_file.read pie in
  assert (fails (fun () -> Pie_run.run ~layout:"small" ~trace:false ~secure:true ~allow_missing_builtins:false
                             ~fill_holes:false { p with n_steps = p.n_steps - 1 }));
  (* a layout without the program's builtins is rejected *)
  assert (fails (fun () -> Pie_run.run ~layout:"plain" ~trace:false ~secure:true ~allow_missing_builtins:false
                             ~fill_holes:false p));
  (* an address outside its declared segment is rejected *)
  let bad = Bytes.copy p.memory in
  Bytes.set_int64_le bad 0 (Int64.logor (Int64.shift_left 1L 63) (Int64.shift_left 1L 47 |> Int64.add 999L));
  assert (fails (fun () -> Pie_run.run ~layout:"small" ~trace:false ~secure:true ~allow_missing_builtins:false
                             ~fill_holes:false { p with memory = bad }));
  Sys.remove pie;
  Sys.remove again
