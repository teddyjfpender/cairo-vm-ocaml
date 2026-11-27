(* Source locations and compiler attributes are checked by serde before the
   Rust VM starts. They need no retained representation in the native VM. *)
type schema =
  | Text | Unsigned of int
  | Optional of schema | Array of schema | Pair of schema * schema
  | Map of bool * schema | Record of (string * schema) list

let fail field = raise (Yojson.Json_error ("Invalid program metadata at " ^ field))
let decimal key = key <> "" && String.for_all (function '0'..'9' -> true | _ -> false) key
let within bits s =
  let n = String.length s in
  n <= (if bits = 64 then 20 else 10) && decimal s && (n = 1 || s.[0] <> '0') &&
  Z.numbits (Z.of_string_base 10 s) <= bits

let rec validate field schema value = match schema, value with
  | Text, `String _ -> ()
  | Unsigned bits, `Int n when n >= 0 && (bits >= Sys.int_size || n lsr bits = 0) -> ()
  | Unsigned bits, `Intlit s when within bits s -> ()
  | Optional _, `Null -> ()
  | Optional s, v -> validate field s v
  | Array s, `List items -> List.iter (validate field s) items
  | Pair (a,b), `List [x;y] -> validate field a x; validate field b y
  | Map (integer_key,s), `Assoc fields ->
      List.iter (fun (key,v) ->
          if integer_key && not (within 64 key) then fail key;
          validate key s v) fields
  | Record spec, `Assoc fields ->
      let seen = ref 0 in
      List.iter (fun (name,v) ->
          let rec check i = function
            | [] -> ()
            | (key,s)::rest ->
                if String.equal name key then begin
                  let bit = 1 lsl i in
                  if !seen land bit <> 0 then fail key;
                  seen := !seen lor bit;
                  validate key s v
                end else check (i+1) rest in
          check 0 spec) fields;
      List.iteri (fun i (key,s) -> match s with
          | Optional _ -> ()
          | _ when !seen land (1 lsl i) = 0 -> fail key
          | _ -> ()) spec
  | Record spec, `List items ->
      let rec check spec items = match spec,items with
        | [], [] -> ()
        | (key,s)::rest, v::vs -> validate key s v; check rest vs
        | _ -> fail field in
      check spec items
  | _ -> fail field

let tracking = Record ["ap_tracking", Record ["group", Unsigned 64; "offset", Unsigned 64];
                       "reference_ids", Map (false, Unsigned 64)]
let attributes = Array (Record ["name", Text; "start_pc", Unsigned 64; "end_pc", Unsigned 64;
                                "value", Text; "flow_tracking_data", Optional tracking])
let rec location = Record ["end_line", Unsigned 32; "end_col", Unsigned 32;
                           "input_file", Record ["filename", Text];
                           "parent_location", Optional (Pair (location,Text));
                           "start_line", Unsigned 32; "start_col", Unsigned 32]
let instruction = Record ["inst", location; "hints", Array (Record ["location",location; "n_prefix_newlines",Unsigned 32])]
let debug = Optional (Record ["instruction_locations", Map (true,instruction)])

let validate_program = function
  | `Assoc fields ->
      let check name schema =
        let seen = ref false in
        List.iter (fun (k,v) -> if String.equal k name then begin
            if !seen then fail name; seen := true; validate name schema v
          end) fields in
      check "attributes" attributes; check "debug_info" debug
  | _ -> ()
