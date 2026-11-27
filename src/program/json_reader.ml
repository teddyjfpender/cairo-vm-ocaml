module J = Yojson.Safe
module U = Yojson.Safe.Util

let space = 0x2020202020202020L

let json_error fmt = Printf.ksprintf (fun m -> raise (Yojson.Json_error m)) fmt

(* Both scanners return byte offsets into the input. Skipping validates the
   entire subtree while avoiding allocation for unused compiler metadata. *)
external string_end : string -> int -> int = "cvm_json_string_end" [@@noalloc]
external skip_value : string -> int -> int = "cvm_json_skip" [@@noalloc]

type projection = Json | Program | Identifiers | Identifier

let from_string ?(projection=Json) src : J.t =
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
  let items close item =
    incr pos;
    if peek () = close then (incr pos; [])
    else
      let rec go acc =
        let acc = item () :: acc in
        match peek () with
        | ',' -> incr pos; go acc
        | c when c = close -> incr pos; List.rev acc
        | _ -> json_error "Expected ',' or '%c' at byte %d" close !pos
      in
      go []
  in
  let rec value projection =
    match peek () with
    | '{' ->
        `Assoc
          (items '}' (fun () ->
               let k = string () in
               expect ':';
               let child = match projection, k with
                 | Program, "identifiers" -> Identifiers
                 | Identifiers, _ -> Identifier
                 | _ -> Json in
               let unused = match projection, k with
                 | Program, ("debug_info" | "attributes") | Identifier, "references" -> true
                 | _ -> false in
               if unused && (peek () = '{' || peek () = '[') then
                 (pos := skip !pos; (k, `Null))
               else (k, value child)))
    | '[' -> `List (items ']' (fun () -> value Json))
    | '"' -> `String (string ())
    | _ ->
        let st = !pos in
        pos := skip st;
        let tok = String.sub src st (!pos - st) in
        if String.for_all (function '0' .. '9' -> true | _ -> false) tok
        then match int_of_string_opt tok with Some i -> `Int i | None -> `Intlit tok
        else
          (try J.from_string tok
           with Yojson.Json_error msg -> json_error "Invalid token at byte %d: %s" st msg)
  in
  let v = value projection in
  match peek () with _ -> json_error "Junk after end of JSON value" | exception Yojson.Json_error _ -> v

let from_file ?projection path =
  let contents = In_channel.with_open_bin path In_channel.input_all in
  from_string ?projection contents
