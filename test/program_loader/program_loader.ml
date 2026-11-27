open Cairovm

let with_json text f =
  let path = Filename.temp_file "cairo-program-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
      Out_channel.with_open_bin path (fun out -> output_string out text);
      f path)

let () =
  let image =
    Printf.sprintf
      {|{"prime":"%s","data":[],"builtins":[],
         "debug_info":{"instruction_locations":{},"source":[{"text":"}\"[\\"}]},
         "identifiers":{"\u0061":{"value":17},"\ud83d\ude80":{"value":123456789012345678901234567890}}}|}
      (Z.to_string Felt.p)
  in
  with_json image (fun path ->
      let program = Program.load_file path in
      let value name = (Hashtbl.find program.identifiers name).i_value in
      assert (value "a" = Some (Z.of_int 17));
      assert (value "🚀" = Some (Z.of_string "123456789012345678901234567890")));
  List.iter (fun text ->
      with_json text (fun path ->
          match Program.load_file path with
          | exception Yojson.Json_error _ -> ()
          | _ -> failwith "malformed JSON accepted"))
    [ {|{"identifiers":{"one":{"references":[true,]}}}|};
      {|{"attributes":{"foo":[0,01]}}|}; {|{"debug_info":{"missing":}}|};
      {|{"debug_info":{"text":"unterminated|}; {|{"bad":[1,]}|};
      {|{"bad":/* comment */1}|}; {|{"bad":truue}|}; "{} trailing" ]

let () =
  let check hints =
    let json = `Assoc ["prime", `String (Z.to_string Felt.p); "data", `List [];
                      "builtins", `List []; "hints", `Assoc hints] in
    match Program.load_json json with
    | exception Program.Parse_error _ -> ()
    | _ -> failwith "negative hint index accepted"
  in
  let tracking = `Assoc ["group", `Int 0; "offset", `Int 0] in
  let flow = `Assoc ["ap_tracking", tracking; "reference_ids", `Assoc ["x", `Int (-1)]] in
  check ["-1", `List []];
  check ["0", `List [`Assoc ["accessible_scopes", `List []; "code", `String ""; "flow_tracking_data", flow]]]

let () =
  let open Json_reader in
  let projection = Only ["used", Json; "nested", Only ["keep", Json]] in
  let text = {|{"unused":[1,2],"\u0075sed":-100,"nested":{"skip":false,"keep":999999999999999999999}}|} in
  assert (from_string ~projection text =
          `Assoc ["used", `Int (-100); "nested", `Assoc ["keep", `Intlit "999999999999999999999"]]);
  List.iter (fun token -> assert (from_string token = Yojson.Safe.from_string token))
    ["0"; "-0"; "999999999999999999"; "-999999999999999999"; "1.25"; "-2e3"; "false"; "null"];
  match from_string ~projection {|{"unused":[0,],"used":0}|} with
  | exception Yojson.Json_error _ -> ()
  | _ -> failwith "malformed unselected value accepted"

let () =
  let invalid member =
    let data = Printf.sprintf {|{"prime":"%s","data":[],"builtins":[],%s}|}
        (Z.to_string Felt.p) member in
    let rejects f = match f () with exception Yojson.Json_error _ -> true | _ -> false in
    with_json data (fun path -> assert (rejects (fun () -> Program.load_file path)));
    assert (rejects (fun () -> Program.load_json (Yojson.Safe.from_string data)))
  in
  List.iter invalid [
    {|"debug_info":{"instruction_locations":{"00":{"inst":{},"hints":[]}}}|};
    {|"debug_info":{"instruction_locations":null}|};
    {|"debug_info":null,"debug_info":null|};
    {|"attributes":[{"name":"x","start_pc":0,"end_pc":0,"value":7}]|};
    {|"attributes":[["x",0,1,"test"]]|};
    {|"attributes":null|};
  ]

let () =
  let word = Z.of_string "0x480680017fff8000" and large = Z.shift_left Z.one 170 in
  let hint = {Program.code=""; scopes=[]; h_group=0; h_offset=0; ref_ids=[]} in
  let p = {Program.data=[|word;large;large;Z.minus_one;Z.zero|]; builtins=[];
    main=Some 0; start=None; end_=None; hints=[0,[hint]]; references=[||]; identifiers=Hashtbl.create 0} in
  let first = !Felt.pool_n in
  let image = Program_image.prepare p in
  assert (!Felt.pool_n = first);
  let fresh () = let vm = Vm.create ~trace:false in ignore (Vm.add_segment vm); vm in
  for i = 1 to 2 do
    Felt.with_temporary_slots (fun () ->
        ignore (Felt.of_z (Z.add large (Z.of_int i)));
        let vm = fresh () in
        Program_image.load image p vm;
        Array.iteri (fun off z ->
            assert (Z.equal (Felt.to_z (Vm.read vm 0 off)) (Z.erem z Felt.p))) p.data;
        assert (vm.icache.(0) = Instruction.decode_word word lor (1 lsl Instruction.ext_shift));
        assert (vm.icache.(1) = 0);
        assert (vm.hi.(0) = Array.length p.data))
  done;
  p.data.(0) <- Z.one;
  match Program_image.load image p (fresh ()) with
  | exception Invalid_argument _ -> ()
  | () -> failwith "stale program image accepted"
