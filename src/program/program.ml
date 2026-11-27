module J = Yojson.Safe
module U = Yojson.Safe.Util

type expr =
  | Reg_ap
  | Reg_fp
  | Int of Z.t
  | Deref of expr
  | Add of expr * expr
  | Sub of expr * expr
  | Mul of expr * expr
  | Neg of expr
  | Tuple of expr list
  | Cast of expr * string

type reference = {
  r_expr : expr; (* the full reference value, e.g. [cast(fp + (-3), felt-pointer)] *)
  r_group : int;
  r_offset : int;
}

type hint = {
  code : string;
  scopes : string list;
  h_group : int;
  h_offset : int;
  ref_ids : (string * int) list; (* full name -> reference index *)
}

type ident = {
  i_type : string;
  i_value : Z.t option;
  i_pc : int option;
  i_destination : string option;
  i_members : (string * int) list; (* struct member offsets *)
  i_member_types : (string * string) list;
}

type t = {
  data : Z.t array;
  builtins : string list;
  main : int option;
  start : int option;
  end_ : int option;
  hints : (int * hint list) list;
  references : reference array;
  identifiers : (string, ident) Hashtbl.t;
}

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

let load_json (j : J.t) : t =
  let prime = z_of_string (U.to_string (U.member "prime" j)) in
  if not (Z.equal prime Felt.p) then raise (Parse_error "Unexpected Cairo field prime");
  let data =
    U.member "data" j |> U.to_list
    |> List.map (fun x -> z_of_string (U.to_string x))
    |> Array.of_list
  in
  let builtins = U.member "builtins" j |> U.to_list |> List.map U.to_string in
  let identifiers = Hashtbl.create 1024 in
  (match U.member "identifiers" j with
  | `Assoc l ->
      List.iter
        (fun (name, v) ->
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
            { i_type = ty; i_value = value; i_pc = pc; i_destination = dest; i_members = members; i_member_types = member_types })
        l
  | _ -> ());
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
    match U.member "reference_manager" j with
    | `Assoc _ as rm ->
        U.member "references" rm |> U.to_list
        |> List.map (fun r ->
               let apt = U.member "ap_tracking_data" r in
               let e = try parse_expr (U.to_string (U.member "value" r)) with Parse_error _ -> Int Z.minus_one in
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
            ( int_of_string pc,
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
                         | `Assoc l -> List.map (fun (k, v) -> (k, U.to_int v)) l
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

(* Word-at-a-time scanning (little-endian): [zero_bytes x] flags the zero
   bytes of [x]; its lowest set bit is exact (the borrow only taints higher
   bytes), and multiplying that bit (as 1 lsl 8k) by bytes 7..0 yields k. *)
let bcast c = Int64.mul 0x0101010101010101L (Int64.of_int (Char.code c))
let quote = bcast '"' and lbrace = bcast '{' and rbrace = bcast '}' and space = bcast ' '
let[@inline] zero_bytes x = Int64.(logand (logand (sub x 0x0101010101010101L) (lognot x)) 0x8080808080808080L)

(* the first index >= i holding '"' (or, unless [in_string], a bracket: '['
   ']' are '{' '}' with bit 5 cleared), or else some index in the last 7 bytes *)
let[@inline] next_special src i ~in_string =
  let i = ref i and found = ref false in
  while (not !found) && !i + 8 <= String.length src do
    let w = String.get_int64_le src !i in
    let m = zero_bytes (Int64.logxor w quote) in
    let m =
      if in_string then m
      else
        let w = Int64.logor w space in
        Int64.(logor m (logor (zero_bytes (logxor w lbrace)) (zero_bytes (logxor w rbrace))))
    in
    if m = 0L then i := !i + 8
    else (
      i := !i + Int64.(to_int (shift_right_logical (mul (shift_right_logical (logand m (neg m)) 7) 0x0001020304050607L) 56));
      found := true)
  done;
  !i

let json_error fmt = Printf.ksprintf (fun m -> raise (Yojson.Json_error m)) fmt

(* A JSON reader building the [Yojson.Safe.t] that [J.from_string] would:
   structure, plain strings and plain integers are read here; escaped strings,
   literals and other numbers go through Yojson itself.  Yojson's comment,
   tuple and variant extensions are not accepted.  debug_info is typically
   >95% of a compiled program and is never needed to execute it: a top-level
   debug_info object or array is skipped by the word scanner (string/escape
   aware) and read as [`Null]. *)
let read_json src : J.t =
  let n = String.length src and pos = ref 0 in
  let peek () =
    while !pos < n && (match src.[!pos] with ' ' | '\n' | '\r' | '\t' -> true | _ -> false) do
      (* indentation comes in runs of spaces *)
      pos := !pos + if !pos + 8 <= n && String.get_int64_le src !pos = space then 8 else 1
    done;
    if !pos < n then src.[!pos] else json_error "Unexpected end of input"
  in
  let expect c = if peek () <> c then json_error "Expected '%c' at byte %d" c !pos else incr pos in
  (* index of the closing quote of the string starting at i *)
  let string_end i =
    let q = ref (i - 1) and fin = ref false in
    while not !fin do
      q := next_special src (!q + 1) ~in_string:true;
      while !q < n && src.[!q] <> '"' do incr q done;
      if !q >= n then json_error "Unterminated string";
      (* count preceding backslashes: odd means the quote is escaped *)
      let k = ref (!q - 1) in
      while src.[!k] = '\\' do decr k done;
      fin := (!q - 1 - !k) land 1 = 0
    done;
    !q
  in
  let string () =
    expect '"';
    let st = !pos in
    let q = string_end st in
    pos := q + 1;
    let raw = String.sub src st (q - st) in
    if String.contains raw '\\' then U.to_string (J.from_string ("\"" ^ raw ^ "\"")) else raw
  in
  (* the end of the object or array starting at i *)
  let skip_container i =
    let depth = ref 0 and j = ref i and fin = ref false in
    while not !fin do
      j := next_special src !j ~in_string:false;
      if !j >= n then json_error "Unexpected end of input";
      (match src.[!j] with
      | '"' -> j := string_end (!j + 1)
      | '{' | '[' -> incr depth
      | '}' | ']' -> decr depth; fin := !depth = 0
      | _ -> ());
      incr j
    done;
    !j
  in
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
  let rec value ~top =
    match peek () with
    | '{' ->
        `Assoc
          (items '}' (fun () ->
               let k = string () in
               expect ':';
               if top && k = "debug_info" && (peek () = '{' || peek () = '[') then (pos := skip_container !pos; (k, `Null))
               else (k, value ~top:false)))
    | '[' -> `List (items ']' (fun () -> value ~top:false))
    | '"' -> `String (string ())
    | _ ->
        let st = !pos in
        while !pos < n && (match src.[!pos] with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '+' | '.' -> true | _ -> false) do
          incr pos
        done;
        let tok = String.sub src st (!pos - st) in
        if tok <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) tok && (tok.[0] <> '0' || tok = "0")
        then match int_of_string_opt tok with Some i -> `Int i | None -> `Intlit tok
        else J.from_string tok
  in
  let v = value ~top:true in
  match peek () with _ -> json_error "Junk after end of JSON value" | exception Yojson.Json_error _ -> v

let load_file path =
  let ic = open_in_bin path in
  let src = really_input_string ic (in_channel_length ic) in
  close_in ic;
  load_json (read_json src)
