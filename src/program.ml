(* CairoZero compiled-program JSON (cairo-compile output). *)

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
  i_size : int option;
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
  prime : Z.t;
}

(* ---- expression parser ---- *)

exception Parse_error of string

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
        Int (Z.of_string (String.sub s st (!pos - st)))
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
  let prime = Z.of_string (U.to_string (U.member "prime" j)) in
  let data =
    U.member "data" j |> U.to_list
    |> List.map (fun x ->
           let s = U.to_string x in
           Z.of_string s)
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
          let size = to_int_opt (U.member "size" v) in
          Hashtbl.replace identifiers name
            { i_type = ty; i_value = value; i_pc = pc; i_destination = dest; i_members = members; i_member_types = member_types; i_size = size })
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
    prime;
  }

(* debug_info is typically >95% of a compiled program and is never needed to
   execute it.  Blank it out with a byte scanner (string/escape aware) before
   handing the remainder to Yojson. *)
let strip_top_level_key (src : string) (key : string) : string =
  let n = String.length src in
  let pat = "\"" ^ key ^ "\"" in
  let pl = String.length pat in
  (* index just past the string whose opening quote is at i - 1 *)
  let rec skip_string i =
    let q = String.index_from src i '"' in
    (* count preceding backslashes: odd means the quote is escaped *)
    let k = ref (q - 1) in
    while src.[!k] = '\\' do decr k done;
    if (q - 1 - !k) land 1 = 1 then skip_string (q + 1) else q + 1
  in
  (* index just past the JSON value starting at i *)
  let skip_value i =
    match src.[i] with
    | '{' | '[' ->
        let depth = ref 0 and j = ref i and fin = ref false in
        while not !fin do
          (match src.[!j] with
          | '"' -> j := skip_string (!j + 1) - 1
          | '{' | '[' -> incr depth
          | '}' | ']' -> decr depth; if !depth = 0 then fin := true
          | _ -> ());
          incr j
        done;
        !j
    | '"' -> skip_string (i + 1)
    | _ ->
        let j = ref i in
        while !j < n && not (String.contains ",}]" src.[!j]) do incr j done;
        !j
  in
  (* walk the top-level object *)
  let rec find i depth =
    if i >= n then None
    else
      match src.[i] with
      | '"' ->
          if depth = 1 && i + pl <= n && String.sub src i pl = pat then Some (i + pl)
          else find (skip_string (i + 1)) depth
      | '{' | '[' -> find (i + 1) (depth + 1)
      | '}' | ']' -> find (i + 1) (depth - 1)
      | _ -> find (i + 1) depth
  in
  match find 0 0 with
  | None -> src
  | Some after_key ->
      let colon = String.index_from src after_key ':' in
      let vstart = ref (colon + 1) in
      while src.[!vstart] = ' ' || src.[!vstart] = '\n' || src.[!vstart] = '\t' || src.[!vstart] = '\r' do
        incr vstart
      done;
      let vend = skip_value !vstart in
      String.sub src 0 !vstart ^ "null" ^ String.sub src vend (n - vend)

let load_file path =
  let ic = open_in_bin path in
  let src = really_input_string ic (in_channel_length ic) in
  close_in ic;
  let src = try strip_top_level_key src "debug_info" with _ -> src in
  load_json (J.from_string src)
