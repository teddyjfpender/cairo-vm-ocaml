module J = Yojson.Safe
module U = Yojson.Safe.Util

let space = 0x2020202020202020L

let json_error fmt = Printf.ksprintf (fun m -> raise (Yojson.Json_error m)) fmt

(* Both scanners return byte offsets into the input. Skipping validates the
   entire subtree while avoiding allocation for unused compiler metadata. *)
external string_end : string -> int -> int = "cvm_json_string_end" [@@noalloc]
external skip_value : string -> int -> int = "cvm_json_skip" [@@noalloc]

type projection =
  | Json
  | Program
  | Debug_info
  | Fields of (string * projection) list
  | Only of (string * projection) list
  | Values of projection
  | Elements of projection
  | Encoded

(* Intern common schema keys and skip unused fields while still validating
   their JSON. Object keys in identifier, member and hint maps remain dynamic. *)
let identifier =
  Only ["type",Json; "value",Json; "pc",Json; "destination",Json;
        "members",Values (Only ["offset",Json; "cairo_type",Json])]

let tracking = Only ["group",Json; "offset",Json]
let reference_manager = Only ["references",Elements (Only ["ap_tracking_data",tracking; "value",Json])]
let hint_table =
  Values (Elements (Only ["code",Json; "accessible_scopes",Json;
    "flow_tracking_data",Only ["ap_tracking",tracking; "reference_ids",Json]]))

external project_key : string -> int ref -> (string * projection) list -> (string * projection) list
  = "cvm_json_project_key" [@@noalloc]

let from_string ?identifiers ?(projection=Json) src : J.t =
  let seen_identifiers = ref false and seen_debug = ref false and seen_attributes = ref false in
  let n = String.length src and pos = ref 0 in
  let peek () =
    while !pos < n && (match src.[!pos] with ' ' | '\n' | '\r' | '\t' -> true | _ -> false) do
      (* indentation comes in runs of spaces *)
      pos := !pos + if !pos + 8 <= n && String.get_int64_le src !pos = space then 8 else 1
    done;
    if !pos < n then src.[!pos] else json_error "Unexpected end of input"
  in
  let expect c = if peek () <> c then json_error "Expected '%c' at byte %d" c !pos else incr pos in
  let string () =
    expect '"';
    let start = !pos in
    let finish = string_end src start in
    if finish = 0 then json_error "Invalid string at byte %d" (start-1);
    pos := abs finish;
    if finish > 0 then String.sub src start (finish-start-1)
    else U.to_string (J.from_string (String.sub src (start-1) (!pos-start+1)))
  in
  let skip i =
    let finish = skip_value src i in
    if finish < 0 then json_error "Invalid JSON at byte %d" (-1-finish);
    finish in
  let fold_items close initial item =
    incr pos;
    if peek () = close then (incr pos; initial)
    else
      let rec go acc =
        let acc = item acc in
        match peek () with
        | ',' -> incr pos; go acc
        | c when c = close -> incr pos; acc
        | _ -> json_error "Expected ',' or '%c' at byte %d" close !pos
      in
      go initial
  in
  let items close item = List.rev (fold_items close [] (fun xs -> item () :: xs)) in
  let rec value projection =
    let token = peek () in
    match projection, token with
    | Encoded, _ ->
        let start = !pos in pos := skip start;
        `String (String.sub src start (!pos-start))
    | Only fields, '{' ->
        `Assoc (List.rev (fold_items '}' [] (fun acc ->
            ignore (peek ());
            let start = !pos in
            let selected = project_key src pos fields in
            match selected with
            | (key, child) :: _ -> expect ':'; (key, value child) :: acc
            | [] when !pos <> start -> expect ':'; pos := skip !pos; acc
            | [] ->
                let key = string () in expect ':';
                match List.assoc_opt key fields with
                | None -> pos := skip !pos; acc
                | Some child -> (key, value child) :: acc)))
    | _, '{' ->
        `Assoc
          (items '}' (fun () ->
               let k = string () in
               expect ':';
               let v = match projection, k with
                 | Program, "identifiers" when not !seen_identifiers ->
                     seen_identifiers := true;
                     if peek () = '{' then begin
                       let add = Option.get identifiers in
                       fold_items '}' () (fun () ->
                           let name = string () in
                           expect ':';
                           add name (value identifier));
                       `Null
                     end else (pos := skip !pos; `Null)
                 | Program, "attributes" ->
                     if !seen_attributes then Program_metadata.fail k;
                     seen_attributes := true;
                     Program_metadata.validate k Program_metadata.attributes (value Json); `Null
                 | Program, "debug_info" ->
                     if !seen_debug then Program_metadata.fail k;
                     seen_debug := true;
                     Program_metadata.validate k Program_metadata.debug (value Debug_info); `Null
                 | Debug_info, "instruction_locations" when peek () = '{' ->
                     fold_items '}' () (fun () ->
                         let key = string () in expect ':';
                         if not (Program_metadata.within 64 key) then Program_metadata.fail key;
                         Program_metadata.validate key Program_metadata.instruction
                           (value (Only ["inst", Json; "hints", Json])));
                     `Assoc []
                 | Program, "reference_manager" -> value reference_manager
                 | Program, "hints" -> value hint_table
                 | Values v, _ -> value v
                 | Debug_info, _ | Program, "identifiers" ->
                     pos := skip !pos; `Null
                 | Fields fields, key -> value (Option.value (List.assoc_opt key fields) ~default:Json)
                 | _ -> value Json in
               k, v))
    | _, '[' ->
        let element = match projection with Elements p -> p | _ -> Json in
        `List (items ']' (fun () -> value element))
    | _, '"' -> `String (string ())
    | _ ->
        let st = !pos in
        pos := skip st;
        let length = !pos - st in
        match token with
        | 't' -> `Bool true | 'f' -> `Bool false | 'n' -> `Null
        | _ ->
            let digits = if token = '-' then st+1 else st in
            let rec integer i acc =
              if i = !pos then Some acc else
                let d = Char.code src.[i] - 48 in
                if d < 0 || d > 9 then None else integer (i+1) (acc*10+d) in
            match (if !pos-digits <= 18 then integer digits 0 else None) with
            | Some v -> `Int (if token = '-' then -v else v)
            | None ->
                let tok = String.sub src st length in
                (try J.from_string tok
                 with Yojson.Json_error msg -> json_error "Invalid token at byte %d: %s" st msg)
  in
  let v = value (if Option.is_some identifiers then Program else projection) in
  match peek () with _ -> json_error "Junk after end of JSON value" | exception Yojson.Json_error _ -> v

let from_file ?identifiers ?projection path =
  let contents = In_channel.with_open_bin path In_channel.input_all in
  from_string ?identifiers ?projection contents
