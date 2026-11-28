(* Execution metadata for a previously parsed Cairo compiler artifact. The
   format contains only typed data. VM memory, compiled closures and native
   pointers are constructed afresh by the normal runner. *)
open Program_types

let magic = "OxCairo\000"
let version = 1
exception Invalid of string
let invalid reason = raise (Invalid reason)

(* Fixed-width little-endian integers make the bounds of each section explicit.
   Small field constants and whole references are shared through indexed tables. *)
module Write = struct
  type t = {
    bytes : Buffer.t;
    names : (string, int) Hashtbl.t;
    numbers : (Z.t, int) Hashtbl.t;
    expressions : (expr, int) Hashtbl.t;
  }

  let byte w = Buffer.add_uint8 w.bytes
  let int w n = Buffer.add_int64_le w.bytes (Int64.of_int n)
  let count w n =
    if n < 0 || n > 0x7fff_ffff then invalid "collection too large";
    Buffer.add_int32_le w.bytes (Int32.of_int n)
  let shared w table x emit =
    match Hashtbl.find_opt table x with
    | Some i -> count w (i + 1)
    | None ->
        Hashtbl.add table x (Hashtbl.length table);
        count w 0; emit ()
  let raw w s = count w (String.length s); Buffer.add_string w.bytes s
  let string w s = shared w w.names s (fun () -> raw w s)
  let number w n = shared w w.numbers n (fun () ->
      byte w (if Z.sign n < 0 then 1 else 0); raw w (Z.to_bits n))
  let option f w = function None -> byte w 0 | Some x -> byte w 1; f w x
  let pair a b w (x,y) = a w x; b w y
  let list f w l = count w (List.length l); List.iter (f w) l
  let array f w a = count w (Array.length a); Array.iter (f w) a

  let rec expr depth w e =
    if depth > 512 then invalid "reference nesting exceeds 512";
    let child = expr (depth+1) w in
    let binary tag a b = byte w tag; child a; child b in
    match e with
    | Reg_ap -> byte w 0 | Reg_fp -> byte w 1
    | Int z -> byte w 2; number w z
    | Deref e -> byte w 3; child e
    | Add (a,b) -> binary 4 a b | Sub (a,b) -> binary 5 a b | Mul (a,b) -> binary 6 a b
    | Neg e -> byte w 7; child e
    | Tuple es -> byte w 8; list (expr (depth+1)) w es
    | Cast (e,t) -> byte w 9; child e; string w t

  let reference w r =
    int w r.r_group; int w r.r_offset;
    shared w w.expressions r.r_expr (fun () -> expr 0 w r.r_expr)
  let hint w h =
    string w h.code; list string w h.scopes; int w h.h_group; int w h.h_offset;
    list (pair string int) w h.ref_ids
  let ident w i =
    string w i.i_type; option number w i.i_value; option int w i.i_pc;
    option string w i.i_destination; list (pair string int) w i.i_members;
    list (pair string string) w i.i_member_types

  let program p =
    let w = { bytes = Buffer.create 65536; names = Hashtbl.create 1024;
              numbers = Hashtbl.create 1024; expressions = Hashtbl.create 128 } in
    Buffer.add_string w.bytes magic; byte w version;
    array number w p.data; list string w p.builtins;
    option int w p.main; option int w p.start; option int w p.end_;
    list (pair int (list hint)) w p.hints; array reference w p.references;
    (* Identifier names are unique in a loaded program. Table traversal varies
       with the runtime hash seed, so emit names in bytewise order. *)
    let identifiers = Hashtbl.to_seq p.identifiers |> List.of_seq in
    list (pair string ident) w
      (List.sort (fun (a, _) (b, _) -> String.compare a b) identifiers);
    Buffer.contents w.bytes
end

module Read = struct
  type 'a table = { mutable entries : 'a array; mutable used : int }
  type t = {
    bytes : string;
    mutable pos : int;
    names : string table;
    numbers : Z.t table;
    expressions : expr table;
  }
  let table initial = {entries = Array.make 128 initial; used = 0}
  let remaining r = String.length r.bytes - r.pos
  let take r n =
    if n < 0 || n > remaining r then invalid "truncated section";
    let start = r.pos in r.pos <- start+n; start
  let byte r = String.get_uint8 r.bytes (take r 1)
  let int r =
    let n = String.get_int64_le r.bytes (take r 8) in
    if n < Int64.of_int min_int || n > Int64.of_int max_int then invalid "integer out of range";
    Int64.to_int n
  let size r =
    let n = Int32.to_int (String.get_int32_le r.bytes (take r 4)) in
    if n < 0 then invalid "negative size";
    n
  let length r =
    let n = size r in
    if n > remaining r then invalid "collection exceeds remaining bytes";
    n
  let shared r table read =
    let id = size r in
    if id > table.used then invalid "unknown table index";
    if id > 0 then table.entries.(id-1) else begin
      let value = read () in
      if table.used = Array.length table.entries then
        table.entries <- Array.append table.entries (Array.make table.used value);
      table.entries.(table.used) <- value; table.used <- table.used+1; value
    end
  let raw r = let n = length r in String.sub r.bytes (take r n) n
  let string r = shared r r.names (fun () -> raw r)
  let number r = shared r r.numbers (fun () ->
      let sign = byte r in
      if sign > 1 then invalid "invalid number sign";
      let n = Z.of_bits (raw r) in if sign = 1 then Z.neg n else n)
  let option f r = match byte r with 0 -> None | 1 -> Some (f r) | _ -> invalid "invalid option"
  let pair a b r = let x = a r in let y = b r in x,y
  let list f r = List.init (length r) (fun _ -> f r)
  let array f r = Array.init (length r) (fun _ -> f r)
  let nonnegative r = let n = int r in if n < 0 then invalid "negative index"; n

  let rec expr depth r =
    if depth > 512 then invalid "reference nesting exceeds 512";
    let child () = expr (depth+1) r in
    let binary make = let a = child () in let b = child () in make a b in
    match byte r with
    | 0 -> Reg_ap | 1 -> Reg_fp | 2 -> Int (number r) | 3 -> Deref (child ())
    | 4 -> binary (fun a b -> Add (a,b)) | 5 -> binary (fun a b -> Sub (a,b))
    | 6 -> binary (fun a b -> Mul (a,b)) | 7 -> Neg (child ())
    | 8 -> Tuple (list (expr (depth+1)) r)
    | 9 -> let e = child () in Cast (e,string r)
    | _ -> invalid "unknown reference expression"

  let reference r =
    let r_group = int r in let r_offset = int r in
    let r_expr = shared r r.expressions (fun () -> expr 0 r) in
    {r_group; r_offset; r_expr}
  let hint r =
    let code = string r in let scopes = list string r in
    let h_group = int r in let h_offset = int r in let ref_ids = list (pair string nonnegative) r in
    {code; scopes; h_group; h_offset; ref_ids}
  let ident r =
    let i_type = string r in let i_value = option number r in let i_pc = option int r in
    let i_destination = option string r in let i_members = list (pair string int) r in
    let i_member_types = list (pair string string) r in
    {i_type; i_value; i_pc; i_destination; i_members; i_member_types}

  let program bytes =
    if not (String.starts_with ~prefix:magic bytes) then invalid "missing format signature";
    let r = {bytes; pos = String.length magic; names = table ""; numbers = table Z.zero;
             expressions = table Reg_ap} in
    if byte r <> version then invalid "unknown format version";
    let data = array number r in let builtins = list string r in
    let main = option int r in let start = option int r in let end_ = option int r in
    let hints = list (pair nonnegative (list hint)) r in let references = array reference r in
    let n = length r in
    let identifiers = Hashtbl.create 1024 in
    for _ = 1 to n do
      let name = string r in let value = ident r in
      if Hashtbl.mem identifiers name then invalid "duplicate identifier";
      Hashtbl.add identifiers name value
    done;
    if remaining r <> 0 then invalid "trailing bytes";
    {data; builtins; main; start; end_; hints; references; identifiers}
end

let encode = Write.program
let decode = Read.program
