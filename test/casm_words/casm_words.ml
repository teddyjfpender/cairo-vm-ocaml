open Cairovm

let read source =
  let projection = Json_reader.(Fields ["classes", Values (Fields ["bytecode", Span])]) in
  let classes = Yojson.Safe.Util.member "classes" (Json_reader.from_string ~projection source) in
  let cls = Yojson.Safe.Util.member "first" classes in
  match Yojson.Safe.Util.member "bytecode" cls with
  | `List [`Int first; `Int last] -> Os_input.decode_words source (first, last)
  | _ -> failwith "missing bytecode span"

let check expected source =
  let words = Array.map Felt.to_z (read source) in
  assert (Array.to_list words = List.map Z.of_int expected)

let refused source =
  match read source with
  | exception _ -> ()
  | _ -> failwith ("accepted malformed witness " ^ source)

let () =
  check [15; 255] {|{"classes":{"first":{"bytecode":["0xf","0xff"]}}}|};
  check [15; 255] {|{"classes":{"first":{"b\u0079tecode":[15,"0\u0078ff"]}}}|};
  check [] {|{"classes":{"first":{"bytecode":[],"bytecode":[1]}}}|};
  check [1] {|{"classes":{"unused":{"bytecode":[-3]},"first":{"bytecode":[1]}}}|};
  refused {|{"classes":{"unused":{"bytecode":[0,]},"first":{"bytecode":[1]}}}|};
  refused {|{"classes":{"first":{"bytecode":["0x1",-1]}}}|};
  refused {|{"classes":{"first":{"bytecode":"[1]"}}}|};
  refused {|{"classes":{"first":{"bytecode":["0x800000000000011000000000000000000000000000000000000000000000001"]}}}|};
  refused {|{"classes":{"first":{"bytecode":[1]}}} trailing|}
