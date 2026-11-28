module J = Yojson.Safe
module U = Yojson.Safe.Util

let space = 0x2020202020202020L

let json_error fmt = Printf.ksprintf (fun m -> raise (Yojson.Json_error m)) fmt

(* Both scanners return byte offsets into the input. Skipping validates the
   entire subtree while avoiding allocation for unused compiler metadata. *)
external string_end : string -> int -> int = "cvm_json_string_end" [@@noalloc]
external skip_value : string -> int -> int = "cvm_json_skip" [@@noalloc]

(* Entries contain only fully parsed immutable JSON. Each reader domain owns
   its table. At most eight keys of at most one MiB are retained. *)
type cache = { entries : (string * J.t) option array; mutable next : int }
external matches_at : string -> int -> string -> bool = "cvm_json_matches_at" [@@noalloc]
let create_cache () = { entries = Array.make 8 None; next = 0 }

type projection =
  | Json
  | Program
  | Debug_info
  | Fields of (string * projection) list
  | Only of (string * projection) list
  | Values of projection
  | Elements of projection
  | Cached of cache
  | Presence (* Validate the value, retaining only whether it is null. *)
  | Encoded
  | Offset (* Validate the entire value and retain its offset in the source. *)

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

(* Advances the cursor only after validating the whole value. On fallback the
   projection below retains the precise error handling of the OCaml reader. *)
external validate_schema : string -> int ref -> Program_metadata.schema -> Program_metadata.schema -> bool
  = "cvm_json_validate_schema" [@@noalloc]

external reference_block : string -> int ref -> bool -> int array -> int
  = "cvm_json_reference_block" [@@noalloc]

let reference_spans src position =
  let cursor = ref !position in
  let rec fill first previous =
    let block = Array.make 2048 0 in
    match reference_block src cursor first block with
    | -1 -> None
    | 0 -> fill false (block :: previous)
    | count ->
        position := !cursor;
        let last = if count = Array.length block then block else Array.sub block 0 count in
        Some (Array.concat (List.rev (last :: previous))) in
  fill true []

external identifier_block : string -> int ref -> int array -> int
  = "cvm_json_identifier_block" [@@noalloc]

external word_block : string -> int ref -> bool -> int array -> int array -> int
  = "cvm_json_word_block" [@@noalloc]

let word_spans src position =
  let cursor = ref !position in
  (* The first cell stores the next word index. Each direct-mapped slot holds
     an earlier word index, string offset and length. *)
  let slots = if String.length src >= 1_048_576 then 4096 else 64 in
  let table = Array.make (1 + 3 * slots) 0 in
  let rec fill first previous =
    let block = Array.make 2048 0 in
    match word_block src cursor first table block with
    | -1 -> None
    | -2 -> fill false (block :: previous)
    | used ->
        position := !cursor;
        Some (Array.concat (List.rev (Array.sub block 0 used :: previous))) in
  fill true []

external struct_block : string -> int ref -> int array -> int
  = "cvm_json_struct_block" [@@noalloc]

let parse_value ?add_struct ?word_offsets ?identifier_batch ?reference_offsets ?identifiers ?debug_span ~projection ~start ~whole src : J.t =
  let seen_identifiers = ref false and seen_debug = ref false and seen_attributes = ref false in
  let seen_words = ref false and seen_references = ref false in
  let n = String.length src and pos = ref start in
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
    | Cached cache, '{' ->
        let start = !pos in
        let rec lookup i =
          if i = Array.length cache.entries then begin
            let tree = value Json in
            let size = !pos - start in
            if size <= 1_048_576 then begin
              cache.entries.(cache.next) <- Some (String.sub src start size, tree);
              cache.next <- (cache.next + 1) mod Array.length cache.entries
            end;
            tree
          end else match cache.entries.(i) with
          | Some (key, tree) when matches_at src start key ->
              pos := start + String.length key; tree
          | _ -> lookup (i + 1)
        in lookup 0
    | Cached _, _ -> value Json
    | Presence, _ ->
        pos := skip !pos;
        if token = 'n' then `Null else `Bool true
    | Offset, _ ->
        let start = !pos in pos := skip start; `Int start
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
                       let ordinary () =
                         let name = string () in expect ':'; add name (value identifier) in
                       (match identifier_batch with
                        | None -> fold_items '}' () ordinary
                        | Some batch ->
                            let rows = Array.make 512 0 in
                            fold_items '}' () (fun () ->
                                let used = identifier_block src pos rows in
                                if used > 0 then batch src rows used
                                else match add_struct with
                                  | None -> ordinary ()
                                  | Some add ->
                                      let used = struct_block src pos rows in
                                      if used > 0 then add src rows used else ordinary ()));
                       `Null
                     end else (pos := skip !pos; `Null)
                 | Program, "attributes" ->
                     if !seen_attributes then Program_metadata.fail k;
                     seen_attributes := true;
                     if not (validate_schema src pos Program_metadata.attributes Program_metadata.instruction) then
                       Program_metadata.validate k Program_metadata.attributes (value Json); `Null
                 | Program, "debug_info" ->
                     if !seen_debug then Program_metadata.fail k;
                     seen_debug := true;
                     ignore (peek ());
                     (match debug_span with
                      | Some (first, last, matched) when first = !pos -> matched := true; pos := last
                      | _ ->
                          if not (validate_schema src pos Program_metadata.debug Program_metadata.instruction) then
                            Program_metadata.validate k Program_metadata.debug (value Debug_info));
                     `Null
                 | Debug_info, "instruction_locations" when peek () = '{' ->
                     fold_items '}' () (fun () ->
                         let key = string () in expect ':';
                         if not (Program_metadata.within 64 key) then Program_metadata.fail key;
                         Program_metadata.validate key Program_metadata.instruction
                           (value (Only ["inst", Json; "hints", Json])));
                     `Assoc []
                 | Program, "reference_manager" ->
                     let first = not !seen_references in
                     seen_references := true;
                     (match reference_offsets with
                      | Some saved when first ->
                          (match reference_spans src pos with
                           | None -> value reference_manager
                           | Some spans -> saved := Some spans; `Null)
                      | _ -> value reference_manager)
                 | Program, "data" when not !seen_words ->
                     seen_words := true;
                     (match word_offsets with
                      | None -> value Json
                      | Some saved ->
                          (match word_spans src pos with
                           | None -> value Json
                           | Some spans -> saved := Some spans; `Null))
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
  if whole then begin
    match peek () with _ -> json_error "Junk after end of JSON value" | exception Yojson.Json_error _ -> ()
  end;
  v

let parse ?identifiers ~projection ~start ~whole src =
  parse_value ?identifiers ~projection ~start ~whole src

let from_string ?identifiers ?(projection=Json) src =
  parse ?identifiers ~projection ~start:0 ~whole:true src

let from_offset ?(projection=Json) src start =
  if start < 0 || start >= String.length src then invalid_arg "JSON value offset";
  parse ~projection ~start ~whole:false src

let from_file ?identifiers ?projection path =
  let contents = In_channel.with_open_bin path In_channel.input_all in
  from_string ?identifiers ?projection contents

external find_debug_span : string -> int array -> bool = "cvm_json_debug_span" [@@noalloc]

external validate_debug_range :
  string -> int array -> Program_metadata.schema -> Program_metadata.schema -> bool
  = "cvm_json_validate_debug_range" [@@noalloc]

let with_program_document ?add_struct ?word_offsets ?add_batch ?reference_offsets ~add_identifier ~consume src =
  let read ?debug_span () =
    Option.iter (fun saved -> saved := None) reference_offsets;
    Option.iter (fun saved -> saved := None) word_offsets;
    (* Ambiguous suffix lookup follows the original identifier table order. *)
    let identifiers = Hashtbl.create 1024 in
    let identifier_batch = Option.map (fun add -> add identifiers) add_batch in
    let add_struct = Option.map (fun add -> add identifiers) add_struct in
    let root = parse_value ?add_struct ?word_offsets ?identifier_batch ?reference_offsets ~identifiers:(add_identifier identifiers) ?debug_span
        ~projection:Program ~start:0 ~whole:true src in
    identifiers, root in
  let full () = let ids, root = read () in consume ids root in
  let bounds = [|0; 0|] in
  if String.length src < 4_000_000 || Domain.recommended_domain_count () < 2 ||
     not (find_debug_span src bounds) then full ()
  else begin
    let first = bounds.(0) and last = bounds.(1) in
    let ready = Semaphore.Binary.make false and release = Semaphore.Binary.make false in
    let verified = Atomic.make false in
    let validate () =
      (* Terminating an OCaml domain collects all domains' nurseries. Leave
         that collection until the consumer has released the temporary JSON. *)
      Fun.protect ~finally:(fun () ->
          Semaphore.Binary.release ready; Semaphore.Binary.acquire release) (fun () ->
          let valid =
            if Domain.recommended_domain_count () >= 4 then
              validate_debug_range src bounds Program_metadata.debug Program_metadata.instruction
            else
              let pos = ref first in
              validate_schema src pos Program_metadata.debug Program_metadata.instruction && !pos = last in
          Atomic.set verified valid) in
    match (try Some (Domain.spawn validate) with Failure _ -> None) with
    | None -> full ()
    | Some worker ->
        Fun.protect ~finally:(fun () -> Semaphore.Binary.release release; Domain.join worker) (fun () ->
            let tentative = try Ok (read ~debug_span:(first,last,ref false) ())
              with e -> Error (e, Printexc.get_raw_backtrace ()) in
            Semaphore.Binary.acquire ready;
            if not (Atomic.get verified) then full () else
            match tentative with
            | Ok (ids,root) -> consume ids root
            | Error (e,bt) -> Printexc.raise_with_backtrace e bt)
  end

external stream_debug : Unix.file_descr -> int array -> (unit -> unit) -> bool
  = "cvm_stream_debug"

let with_program_slices ~add_identifier ~add_batch ~add_struct ~consume ~bounds ~fd read =
  let first = bounds.(0) in
  let matched = ref false and ids = Hashtbl.create 1024 and tentative = ref None in
  let word_offsets = ref None and reference_offsets = ref None in
  let parse () =
    match read () with
    | None -> ()
    | Some source ->
        (* The surrounding root must confirm that the removed bytes were
           precisely the value of its debug_info field. Otherwise retry the
           complete source, which preserves ordinary parsing diagnostics. *)
        try
          let root = parse_value ~add_struct:(add_struct ids) ~word_offsets
              ~identifier_batch:(add_batch ids) ~reference_offsets
              ~identifiers:(add_identifier ids) ~debug_span:(first, first, matched)
              ~projection:Program ~start:0 ~whole:true source in
          tentative := Some (source, root)
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ | Invalid_argument _ -> () in
  let valid = stream_debug fd bounds parse in
  match !tentative with
  | Some (source, root) when !matched && valid ->
      Some (consume source !word_offsets !reference_offsets ids root)
  | _ -> None

let program_document ~add_identifier src =
  with_program_document ~add_identifier ~consume:(fun ids root -> ids,root) src
