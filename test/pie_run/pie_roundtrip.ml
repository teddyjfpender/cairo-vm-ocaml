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

let check_stream path =
  let all = Pie_file.read path in
  let metadata,source = Pie_file.read_deferred path in
  assert (metadata = {all with memory=Bytes.empty});
  let exception Stop in
  (try Pie_file.iter_memory source (fun _ -> raise Stop) with Stop -> ());
  for _ = 1 to 2 do
    let pos = ref 0 in
    Pie_file.iter_memory source (fun bytes ->
        let n = Bytes.length bytes in
        assert (n mod Pie_file.cell_bytes = 0);
        assert (bytes = Bytes.sub all.memory !pos n);
        pos := !pos+n);
    assert (!pos = Bytes.length all.memory)
  done

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
  (* A declared execution-segment tail with no cells consumes no memory.
     Secure replay detects the discrepancy with the actual final AP. *)
  let long_tail = { p with execution_segment = { p.execution_segment with size = 1 lsl 40 } } in
  let replay secure = Pie_run.run ~layout:"small" ~trace:false ~secure
      ~allow_missing_builtins:false ~fill_holes:false long_tail in
  assert (Segment.slen (replay false).runner.vm.segs.(1) = Segment.slen first.vm.segs.(1));
  assert (fails (fun () -> replay true));
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

let () =
  check_stream "rust4-bitwise.zip";
  let pie = Pie_file.read "rust4-bitwise.zip" in
  let result = Pie_run.run ~layout:"all_cairo" ~trace:true ~secure:true
      ~allow_missing_builtins:false ~fill_holes:false pie in
  assert (result.runner.vm.steps = pie.n_steps);
  assert (Artifacts.output_lines result.runner = ["0"])

let () =
  let saved = Felt.of_z (Z.shift_left Z.one 193) in
  let first = !Felt.pool_n in
  for _ = 1 to 3 do
    Pie_run.replay_file "rust4-bitwise.zip";
    assert (!Felt.pool_n = first);
    assert (Z.equal (Felt.to_z saved) (Z.shift_left Z.one 193))
  done;
  (match Felt.with_temporary_slots (fun () ->
       ignore (Felt.of_z (Z.shift_left Z.one 200)); raise Exit) with
   | exception Exit -> () | _ -> assert false);
  assert (!Felt.pool_n = first)


let () = match Array.to_list Sys.argv with
  | [_; "--stream"; path] -> check_stream path
  | [_; "--invalid-stream"; path] ->
      let _,source = Pie_file.read_deferred path in
      (match Pie_file.iter_memory source ignore with
       | exception (Errors.Vm_error _ | Failure _) -> ()
       | () -> failwith "Invalid memory member accepted")
  | _ -> ()
