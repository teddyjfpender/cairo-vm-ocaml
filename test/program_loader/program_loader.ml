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

let () =
  let open Program in
  let huge = Z.shift_left Z.minus_one 300 in
  let e = Tuple [Reg_ap; Reg_fp; Deref (Int huge); Add (Int Z.zero, Reg_ap);
                 Sub (Reg_fp, Int Z.one); Neg (Mul (Reg_fp, Cast (Reg_ap, "foo*")))] in
  let h = {code="shared string"; scopes=["shared string"]; h_group=(-3); h_offset=9;
           ref_ids=["a",0; "a.b",1]} in
  let ids = Hashtbl.create 1 in
  Hashtbl.add ids "__main__.main" {i_type="function"; i_value=Some huge; i_pc=Some 0;
    i_destination=Some "shared string"; i_members=["a",3]; i_member_types=["a","foo*"]};
  let p = {data=[|huge; Z.zero; huge; Z.one|]; builtins=["output"]; main=Some 0;
           start=None; end_=Some 1; hints=[0,[h;h]]; identifiers=ids;
           references=[|{r_expr=e; r_group=3; r_offset=min_int}; {r_expr=e; r_group=1; r_offset=max_int}|]} in
  let packed = pack p in
  with_json packed (fun path ->
      let q = load_file path in
      assert (q.data = p.data && q.builtins = p.builtins && q.main = p.main
              && q.start = p.start && q.end_ = p.end_ && q.references = p.references
              && q.hints = p.hints && Hashtbl.find ids "__main__.main" = Hashtbl.find q.identifiers "__main__.main");
      assert (q.references.(0).r_expr == q.references.(1).r_expr);
      assert (q.data.(0) == q.data.(2)));
  List.iter (fun malformed ->
      with_json malformed (fun path -> match load_file path with
        | exception Parse_error _ -> ()
        | _ -> failwith "invalid packed program accepted"))
    [packed ^ "x"; String.sub packed 0 (String.length packed-1); Packed_program.magic ^ "\255"]

let () =
  let parse member =
    let raw = "{" ^ member ^ "}" in
    Json_reader.from_string ~projection:Json_reader.Program ~identifiers:(fun _ _ -> ()) raw in
  let accepted member = ignore (parse member) in
  let rejected member = match parse member with
    | exception Yojson.Json_error _ -> ()
    | _ -> failwith ("invalid metadata accepted " ^ member) in
  accepted {|"attributes":[{"name":"\u0078","start_pc":18446744073709551615,"end_pc":0,"value":"x"}]|};
  accepted {|"attributes":[["x",0,1,"y",null]]|};
  accepted {|"debug_info":{"\u0069nstruction_locations":{},"file_contents":{"x":"content"}}|};
  rejected {|"attributes":[{"name":"x","name":"y","start_pc":0,"end_pc":1,"value":"x"}]|};
  rejected {|"attributes":[{"name":"x","start_pc":18446744073709551616,"end_pc":0,"value":"x"}]|};
  rejected {|"debug_info":{"instruction_locations":{"1":{}}}|};
  rejected {|"debug_info":{"instruction_locations":{},"file_contents":[null,]}}|}

let () =
  let src = {|[{"x":13},{"x":27}, {"x":"\u0061"}]|} in
  let open Json_reader in
  let entries = from_string ~projection:(Elements Offset) src |> Yojson.Safe.Util.to_list in
  let read offset = from_offset src (Yojson.Safe.Util.to_int offset) in
  assert (List.map read entries = Yojson.Safe.Util.to_list (Yojson.Safe.from_string src));
  List.iter (fun offset -> match from_offset src offset with
      | exception Invalid_argument _ -> ()
      | _ -> failwith "invalid offset accepted") [-1; String.length src];
  match from_string ~projection:(Elements Offset) {|[{"x":false},{"x":01}]|} with
  | exception Yojson.Json_error _ -> ()
  | _ -> failwith "malformed deferred witness accepted"

let () =
  let read s = Json_reader.from_string ~projection:(Only ["keep", Json]) s in
  for width = 0 to 24 do
    let indent = String.make width ' ' in
    let doc between = "{\"omit\":[" ^ indent ^ between ^ indent ^ "1],\"keep\":2}" in
    assert (read (doc "\r\n\t") = `Assoc ["keep", `Int 2]);
    match read (doc "\011") with
    | exception Yojson.Json_error _ -> ()
    | _ -> failwith "invalid JSON control character in indentation"
  done

let () =
  (* Exercise the concurrent compiler reader with both a genuine closing
     indentation and an earlier nested brace sharing that indentation. *)
  let large = String.make 4_000_000 'x' in
  let load indent fields =
    let doc = Printf.sprintf
        "{\n%s\"debug_info\": {\n%s\"file_contents\":{\"src\":\"%s\"},%s\n%s},\n%s\"prime\":\"%s\",\"data\":[],\"builtins\":[]}"
        indent indent large fields indent indent (Z.to_string Felt.p) in
    with_json doc Program.load_file in
  List.iter (fun indent ->
      let valid = load indent "\"instruction_locations\":{}" in
      assert (Array.length valid.data = 0);
      let boundary = Printf.sprintf "\"extra\":{\"a\":1\n%s},\"instruction_locations\":{}" indent in
      let fallback = load indent boundary in
      assert (Array.length fallback.data = 0);
      let invalid = Printf.sprintf "\"extra\":{\"a\":1\n%s},\"instruction_locations\":false" indent in
      match load indent invalid with
      | exception Yojson.Json_error _ -> ()
      | _ -> failwith "invalid debug metadata after a speculative boundary") ["  "; "    "]

(* Deterministically exercise file growth and truncation between observing the
   descriptor's size and its positional reads. Fallback still starts at zero. *)
external pread_program : Unix.file_descr -> int -> string option = "cvm_pread_program"

let () =
  let contents = String.init 65537 (fun i -> Char.chr (i land 255)) in
  with_json contents (fun path ->
      In_channel.with_open_bin path (fun ic ->
          let fd = Unix.descr_of_in_channel ic and size = String.length contents in
          assert (pread_program fd size = Some contents);
          assert (pread_program fd (size - 1) = None);
          assert (pread_program fd (size + 1) = None);
          assert (In_channel.input_all ic = contents)))

let () =
  let open Json_reader in
  let cache = create_cache () in
  let parse = from_string ~projection:(Fields ["classes", Values (Cached cache)]) in
  let input obj = {|{"classes":{"same":|} ^ obj ^ "}}" in
  let read str = assert (parse str = Yojson.Safe.from_string str) in
  let first = {|{"code":["one",{"nested":42}]}|} in
  read (input first);
  read (input first);
  read (input {|{"code":["one",{"nested":43}]}|});
  read (input {|{"code":["one",{"nested":42}],"extra":true}|});
  read (input "null");
  for i = 0 to 11 do read (input (Printf.sprintf {|{"v":%d}|} i)) done;
  read (input first);
  match parse (input (first ^ "x")) with
  | exception Yojson.Json_error _ -> ()
  | _ -> failwith "invalid bytes following a cached class were accepted"

let () =
  let padding = String.make 4_100_000 'x' in
  let repeated = {|{"nested":{"key":"a long string with a closing } and [ bracket inside it"}}|} in
  let document extra =
    Printf.sprintf
      "{\n  \"debug_info\": {\n    \"file_contents\":{\"x\":\"%s\"},\"extra\":%s,\"extra\":%s,%s\n  },\n  \"ignored\":{}}"
      padding repeated repeated extra in
  let visits = ref 0 in
  let run extra consume =
    Json_reader.with_program_document ~add_identifier:(fun _ _ _ -> ())
      ~consume:(fun _ _ -> incr visits; consume ()) (document extra) in
  run {|"instruction_locations":{}|} (fun () ->
      run {|"instruction_locations":{}|} (fun () -> ()));
  assert (!visits = 2);
  (* A nested closing brace with root indentation forces a complete retry. *)
  run "\"unknown\":{\"ok\":true\n  },\"instruction_locations\":{}" (fun () -> ());
  assert (!visits = 3);
  (match run {|"instruction_locations":{}|} (fun () -> raise Exit) with
   | exception Exit -> ()
   | _ -> failwith "consumer exception lost");
  assert (!visits = 4);
  (match run "\"extra\":{\"nested\":{\"key\":\"a long string with a closing } and [ bracket inside it\",}},\"instruction_locations\":{}"
           (fun () -> ()) with
   | exception Yojson.Json_error _ -> ()
   | _ -> failwith "malformed repeated span accepted");
  (match run "\"unknown\":{\"ok\":true\n  },\"instruction_locations\":false" (fun () -> ()) with
   | exception Yojson.Json_error _ -> ()
   | _ -> failwith "malformed parallel document accepted");
  assert (!visits = 4)

let () =
  let open Json_reader in
  let proj = Only ["error", Presence] in
  List.iter (fun (source, expected) ->
      assert (from_string ~projection:proj source = expected))
    ["{}", `Assoc [];
     "{\"error\":null}", `Assoc ["error", `Null];
     "{\"error\":\"line\\n2\"}", `Assoc ["error", `Bool true];
     "{\"error\":[1,{\"code\":2}]}", `Assoc ["error", `Bool true]];
  (match from_string ~projection:proj "{\"error\":[1,]}" with
   | _ -> assert false | exception Yojson.Json_error _ -> ())

let () =
  let prime = Z.to_string Felt.p in
  let check fields =
    let source = Printf.sprintf {|{"prime":"%s","data":[],"builtins":[],%s}|} prime fields in
    let expected = Program.load_json (Yojson.Safe.from_string source) |> Program.pack in
    with_json source (fun path -> assert (Program.pack (Program.load_file path) = expected)) in
  let reference expression =
    Printf.sprintf {|{"ap_tracking_data":{"group":1,"offset":2},"pc":3,"value":%s}|} expression in
  (* Cross a native block boundary before an escaped expression or a
     noncanonical record forces fallback. Duplicate root keys still use the
     first manager, while duplicate identifier names replace older entries. *)
  let prefix = List.init 512 (fun _ -> reference {|"[cast(ap + (-2), felt**)]"|}) in
  List.iter (fun last ->
      let references = String.concat "," (prefix @ [last]) in
      check (Printf.sprintf
        {|"identifiers":{"a":{"type":"const","value":7},"s":{"type":"struct","members":{"m":{"offset":2,"cairo_type":"felt"}}},"\u0061":{"type":"const","value":-987654321098765432109876},"b":{"pc":5,"type":"label"},"b":{"type":"alias","destination":"a"}},"reference_manager":{"references":[%s]},"reference_manager":{"references":[]}|}
        references))
    [reference {|"x\n\t\"y\\"|}; reference {|"\u0061p"|};
     {|{"value":"ap","pc":0,"other":[1,2],"ap_tracking_data":{"offset":0,"group":2}}|}];
  check {|"reference_manager":{"references":[]},"reference_manager":{"references":[{"ap_tracking_data":{"group":0,"offset":0},"pc":0,"value":"ap"}]}|};
  check {|"identifiers":{"first":{"type":"const","value":"0xbeef"},"last":{"type":"const","value":17,"value":99},"p":{"type":"label","pc":-2},"s":{"type":"alias","destination":"\u0061"}}|}

let () =
  (* The apparent midpoint member belongs to "extra", not to the instruction
     map. Both partitions must validate up to precisely their own delimiter. *)
  let location = {|{"end_line":1,"end_col":1,"input_file":{"filename":"a"},"start_line":1,"start_col":1}|} in
  let instruction = {|{"hints":[],"inst":|} ^ location ^ "}" in
  let padding = String.make 8_300_000 'a' in
  let source last =
    Printf.sprintf
      "{\n  \"debug_info\": {\n    \"instruction_locations\": {\n      \"0\": {\"hints\":[],\"inst\":%s,\"extra\":{\"long\":\"%s%s\",\n      \"123\":%s},\"tail\":\"%s\"},\n      \"1\":%s\n    }\n  },\n  \"hints\":{},\"prime\":\"%s\",\"data\":[],\"builtins\":[]}"
      location padding (String.make 8192 'a') instruction padding last (Z.to_string Felt.p) in
  with_json (source instruction) (fun path -> ignore (Program.load_file path));
  with_json (source {|{"hints":false,"inst":null}|}) (fun path ->
      match Program.load_file path with
      | exception Yojson.Json_error _ -> ()
      | _ -> failwith "invalid instruction after a nested partition candidate")
