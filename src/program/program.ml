module J = Yojson.Safe
module U = Yojson.Safe.Util

include Program_types

(* ---- expression parser ---- *)

exception Parse_error of string

let z_of_string s = try Z.of_string s with Invalid_argument _ -> raise (Parse_error ("Invalid number " ^ s))

let parse_expr (s : string) : expr =
  let n = String.length s in
  let pos = ref 0 in
  let peek () =
    while !pos < n && (s.[!pos] = ' ' || s.[!pos] = '\n' || s.[!pos] = '\t') do
      incr pos
    done;
    if !pos < n then Some s.[!pos] else None
  in
  let expect c =
    match peek () with
    | Some c' when c' = c -> incr pos
    | _ -> raise (Parse_error (Printf.sprintf "expected '%c' at %d in %s" c !pos s))
  in
  let ident () =
    ignore (peek ());
    let st = !pos in
    while
      !pos < n
      && (match s.[!pos] with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' -> true | _ -> false)
    do
      incr pos
    done;
    String.sub s st (!pos - st)
  in
  (* type expressions: names, pointers, tuples (named or not) *)
  let rec type_expr () =
    let st = !pos in
    let depth = ref 0 in
    let fin = ref false in
    while not !fin do
      if !pos >= n then fin := true
      else
        match s.[!pos] with
        | '(' ->
            incr depth;
            incr pos
        | ')' -> if !depth = 0 then fin := true else (decr depth; incr pos)
        | ',' when !depth = 0 -> fin := true
        | _ -> incr pos
    done;
    String.trim (String.sub s st (!pos - st))
  and atom () =
    match peek () with
    | Some '[' ->
        incr pos;
        let e = sum () in
        expect ']';
        Deref e
    | Some '(' ->
        incr pos;
        let e = sum () in
        (match peek () with
        | Some ',' ->
            let items = ref [ e ] in
            while peek () = Some ',' do
              incr pos;
              if peek () <> Some ')' then items := sum () :: !items
            done;
            expect ')';
            Tuple (List.rev !items)
        | _ ->
            expect ')';
            e)
    | Some '-' ->
        incr pos;
        Neg (atom ())
    | Some ('0' .. '9') ->
        let st = !pos in
        while
          !pos < n && (match s.[!pos] with '0' .. '9' | 'x' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
        do
          incr pos
        done;
        Int (z_of_string (String.sub s st (!pos - st)))
    | Some _ -> (
        let id = ident () in
        match id with
        | "ap" -> Reg_ap
        | "fp" -> Reg_fp
        | "cast" ->
            expect '(';
            let e = sum () in
            expect ',';
            let t = type_expr () in
            expect ')';
            Cast (e, t)
        | "" -> raise (Parse_error ("unexpected char in " ^ s))
        | _ ->
            (* named tuple element "x=..." not supported *)
            raise (Parse_error ("unsupported identifier " ^ id ^ " in " ^ s)))
    | None -> raise (Parse_error ("unexpected end in " ^ s))
  and product () =
    let e = ref (atom ()) in
    while peek () = Some '*' do
      incr pos;
      e := Mul (!e, atom ())
    done;
    !e
  and sum () =
    let e = ref (product ()) in
    let continue = ref true in
    while !continue do
      match peek () with
      | Some '+' ->
          incr pos;
          e := Add (!e, product ())
      | Some '-' ->
          incr pos;
          e := Sub (!e, product ())
      | _ -> continue := false
    done;
    !e
  in
  let e = sum () in
  if peek () <> None then raise (Parse_error ("trailing input in " ^ s));
  e

(* ---- JSON loading ---- *)

let to_int_opt j = match j with `Int i -> Some i | `Intlit s -> Some (int_of_string s) | _ -> None

let z_of_json = function
  | `Int i -> Z.of_int i
  | `Intlit s -> Z.of_string s
  | `String s -> Z.of_string s
  | _ -> raise (Parse_error "expected number")

let add_identifier identifiers name v =
  let ty = match U.member "type" v with `String s -> s | _ -> "" in
  let value = match U.member "value" v with `Null -> None | x -> (try Some (z_of_json x) with _ -> None) in
  let pc = to_int_opt (U.member "pc" v) in
  let dest = match U.member "destination" v with `String s -> Some s | _ -> None in
  let members =
    match U.member "members" v with
    | `Assoc ms ->
        List.filter_map (fun (m, mv) -> Option.map (fun o -> (m, o)) (to_int_opt (U.member "offset" mv))) ms
    | _ -> []
  in
  let member_types =
    match U.member "members" v with
    | `Assoc ms ->
        List.filter_map (fun (m, mv) -> match U.member "cairo_type" mv with `String t -> Some (m, t) | _ -> None) ms
    | _ -> []
  in
  Hashtbl.replace identifiers name
    { i_type = ty; i_value = value; i_pc = pc; i_destination = dest; i_members = members; i_member_types = member_types }

(* Kind numbers and row fields match json_identifiers.h. Sharing these empty
   immutable records leaves identifier insertion and duplicate replacement
   in exactly the order used by the general reader. *)
let identifier_kinds =
  Array.map (fun i_type ->
      {i_type; i_value=None; i_pc=None; i_destination=None; i_members=[]; i_member_types=[]})
    [|""; "reference"; "type_definition"; "namespace"; "function"; "alias"; "const"; "label"|]

let add_identifier_batch table source rows used =
  for i = 0 to used / 8 - 1 do
    let p = i * 8 in
    let name = String.sub source rows.(p) rows.(p + 1) in
    let common = identifier_kinds.(rows.(p + 2)) in
    let pc = rows.(p + 3) and dest = rows.(p + 4) and number = rows.(p + 6) in
    let identifier =
      if pc < 0 && dest < 0 && number < 0 then common
      else
        {common with
         i_pc = (if pc < 0 then None else Some pc);
         i_destination = (if dest < 0 then None else Some (String.sub source dest rows.(p + 5)));
         i_value = (if number < 0 then None else Some (Z.of_string (String.sub source number rows.(p + 7))))} in
    Hashtbl.replace table name identifier
  done

let add_struct table source rows used =
  let members = ref [] and types = ref [] in
  for i = (used - 2) / 5 - 1 downto 0 do
    let p = 2 + 5 * i in
    let name = String.sub source rows.(p) rows.(p + 1) in
    let typ = String.sub source rows.(p + 2) rows.(p + 3) in
    members := (name, rows.(p + 4)) :: !members;
    types := (name, typ) :: !types
  done;
  let name = String.sub source rows.(0) rows.(1) in
  Hashtbl.replace table name
    {i_type = "struct"; i_pc = None; i_value = None; i_destination = None;
     i_members = !members; i_member_types = !types}

let load_with_identifiers ?word_offsets ?reference_offsets identifiers (j : J.t) : t =
  let prime = z_of_string (U.to_string (U.member "prime" j)) in
  if not (Z.equal prime Felt.p) then raise (Parse_error "Unexpected Cairo field prime");
  let data = match word_offsets with
    | Some (src, rows) ->
        let words = Array.make (Array.length rows / 2) Z.zero in
        for i = 0 to Array.length words - 1 do
          let pos = rows.(2 * i) and len = rows.(2 * i + 1) in
          words.(i) <- if pos < 0 then words.(-pos - 1) else
            try Z.of_substring src ~pos ~len
            with Invalid_argument _ -> raise (Parse_error ("Invalid number " ^ String.sub src pos len))
        done;
        words
    | None ->
        let words = U.member "data" j |> U.to_list in
        let parse x = z_of_string (U.to_string x) in
        if List.compare_length_with words 128 < 0 then Array.of_list (List.map parse words)
        else
          let parsed = Hashtbl.create 512 in
          let word x =
            let text = U.to_string x in
            match Hashtbl.find_opt parsed text with
            | Some z -> z
            | None ->
                let z = z_of_string text in
                if Hashtbl.length parsed < 8192 then Hashtbl.add parsed text z;
                z in
          Array.of_list (List.map word words)
  in
  let builtins = U.member "builtins" j |> U.to_list |> List.map U.to_string in
  let rec resolve name depth =
    if depth > 32 then None
    else
      match Hashtbl.find_opt identifiers name with
      | Some { i_type = "alias"; i_destination = Some d; _ } -> resolve d (depth + 1)
      | x -> x
  in
  let label n = match resolve n 0 with Some { i_pc = Some pc; _ } -> Some pc | _ -> None in
  let main_scope = match U.member "main_scope" j with `String s -> s | _ -> "__main__" in
  let refs =
    let expressions = Hashtbl.create (if Array.length data >= 4096 then 512 else 64) in
    let parse value =
      match Hashtbl.find_opt expressions value with
      | Some e -> e
      | None ->
          let e = try parse_expr value with Parse_error _ -> Int Z.minus_one in
          Hashtbl.add expressions value e; e in
    match reference_offsets, U.member "reference_manager" j with
    | Some (source, spans), _ ->
        Array.init (Array.length spans / 4) (fun i ->
            let p = i * 4 in
            let start = spans.(p + 2) and length = spans.(p + 3) in
            let expr =
              if length >= 0 then String.sub source start length
              else U.to_string (J.from_string (String.sub source (start - 1) (2 - length))) in
            {r_group = spans.(p); r_offset = spans.(p + 1); r_expr = parse expr})
    | None, (`Assoc _ as rm) ->
        U.member "references" rm |> U.to_list
        |> List.map (fun r ->
               let apt = U.member "ap_tracking_data" r in
               let e = parse (U.to_string (U.member "value" r)) in
               {
                 r_expr = e;
                 r_group = U.to_int (U.member "group" apt);
                 r_offset = U.to_int (U.member "offset" apt);
               })
        |> Array.of_list
    | _ -> [||]
  in
  let hints =
    match U.member "hints" j with
    | `Assoc l ->
        List.map
          (fun (pc, hs) ->
            let pc = int_of_string pc in
            if pc < 0 then raise (Parse_error "Negative hint offset");
            ( pc,
              U.to_list hs
              |> List.map (fun h ->
                     let ftd = U.member "flow_tracking_data" h in
                     let apt = U.member "ap_tracking" ftd in
                     {
                       code = U.to_string (U.member "code" h);
                       scopes = U.member "accessible_scopes" h |> U.to_list |> List.map U.to_string;
                       h_group = U.to_int (U.member "group" apt);
                       h_offset = U.to_int (U.member "offset" apt);
                       ref_ids =
                         (match U.member "reference_ids" ftd with
                         | `Assoc l -> List.map (fun (k, v) ->
                             let id = U.to_int v in
                             if id < 0 then raise (Parse_error "Negative hint reference index");
                             k, id) l
                         | _ -> []);
                     }) ))
          l
    | _ -> []
  in
  {
    data;
    builtins;
    main = label (main_scope ^ ".main");
    start = label (main_scope ^ ".__start__");
    end_ = label (main_scope ^ ".__end__");
    hints;
    references = refs;
    identifiers;
  }

let load_json j =
  Program_metadata.validate_program j;
  let identifiers = Hashtbl.create 1024 in
  (match U.member "identifiers" j with
   | `Assoc entries -> List.iter (fun (name, v) -> add_identifier identifiers name v) entries
   | _ -> ());
  load_with_identifiers identifiers j

external read_program : Unix.file_descr -> int -> string option = "cvm_pread_program"

let load_projection source word_offsets reference_offsets ids root =
  let spans offsets = Option.map (fun rows -> source, rows) offsets in
  load_with_identifiers ?word_offsets:(spans word_offsets)
    ?reference_offsets:(spans reference_offsets) ids root

let load_bytes contents =
  if String.starts_with ~prefix:Packed_program.magic contents then
    (try Packed_program.decode contents
     with Packed_program.Invalid reason -> raise (Parse_error ("Invalid packed program: " ^ reason)))
  else
    let word_offsets = ref None and reference_offsets = ref None in
    let consume ids root = load_projection contents !word_offsets !reference_offsets ids root in
    Json_reader.with_program_document ~word_offsets ~add_struct ~add_batch:add_identifier_batch
      ~reference_offsets ~add_identifier ~consume contents

external read_sections : Unix.file_descr -> int array -> string option = "cvm_pread_program_sections"
external find_file_span : Unix.file_descr -> int -> int array -> bool = "cvm_file_span" [@@noalloc]

let load_file path =
  In_channel.with_open_bin path (fun ic ->
      let fd = Unix.descr_of_in_channel ic in
      let stat = Unix.fstat fd in
      let size = stat.st_size and cpus = Domain.recommended_domain_count () in
      let streaming_read () = load_bytes (In_channel.input_all ic) in
      if stat.st_kind <> Unix.S_REG || size < 4_000_000 || size > Sys.max_string_length || cpus < 2
      then streaming_read ()
      else
        let full () = match read_program fd size with
          | Some source -> load_bytes source
          | None -> streaming_read () in
        let bounds = Array.make 7 0 in
        if size < 32 lsl 20 || cpus < 4 || not (find_file_span fd size bounds) then full ()
        else
          let read () = read_sections fd [|size; 0; bounds.(0); bounds.(1); size - bounds.(1)|] in
          match Json_reader.with_program_slices ~add_identifier ~add_batch:add_identifier_batch
                  ~add_struct ~consume:load_projection ~bounds ~fd read with
          | Some program -> program
          | None -> full ())

let pack program =
  try Packed_program.encode program
  with Packed_program.Invalid reason -> raise (Parse_error ("Cannot pack program: " ^ reason))
