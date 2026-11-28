(* The sequencer searches simultaneously through the modified leaves and the
   old and new commitment trees. Only branches containing updates are opened. *)
open Errors

type update = Empty | Leaf | Branch of update * update | Stem of int * Z.t * update
type edge = { length : int; path : Z.t; bottom : Z.t }
type preimage = Binary of Z.t * Z.t | Edge of edge
type descents = ((int * Z.t), (int * Z.t)) Hashtbl.t

let height z =
  if Z.sign z < 0 || Z.gt z (Z.of_int 251) then fail "Invalid Patricia height";
  Z.to_int z

let preimage = function
  | [l; r] -> Binary (l, r)
  | [n; path; bottom] ->
      let length = height n in
      if Z.numbits path > length then fail "Invalid Patricia edge path";
      Edge { length; path; bottom }
  | _ -> fail "Invalid Patricia preimage"

(* A unary path stores its bits right-aligned, with the first branch at
   bit length-1. Inserting a singleton needs one node even in a 251-bit tree. *)
let stem length bits child =
  if length = 0 then child else Stem (length, Z.extract bits 0 length, child)

let prefix bits length count = Z.extract bits (length-count) count

let rec insert tree height key =
  if height = 0 then Leaf else match tree with
  | Empty -> stem height key Leaf
  | Leaf -> fail "Unexpected Patricia leaf"
  | Branch (l,r) ->
      if Z.testbit key (height-1) then Branch (l, insert r (height-1) key)
      else Branch (insert l (height-1) key, r)
  | Stem (length, bits, child) ->
      let other = prefix key height length in
      let diff = Z.logxor bits other in
      if Z.equal diff Z.zero then Stem (length, bits, insert child (height-length) key)
      else
        let low = Z.numbits diff - 1 in
        let common = length-low-1 in
        let old = stem low bits child and fresh = stem (height-common-1) key Leaf in
        let split = if Z.testbit bits low then Branch (fresh,old) else Branch (old,fresh) in
        stem common (Z.shift_right bits (low+1)) split

let update_children = function
  | Branch (a,b) -> a,b
  | Stem (length,bits,child) ->
      let rest = stem (length-1) bits child in
      if Z.testbit bits (length-1) then Empty,rest else rest,Empty
  | _ -> fail "Expected Patricia branch"

let rec follow tree length bits =
  if length = 0 then tree else match tree with
  | Stem (n,path,child) ->
      let k = min n length in
      let difference = Z.logxor (prefix path n k) (prefix bits length k) in
      if not (Z.equal difference Z.zero) then begin
        if k = length && Z.equal difference Z.one then Empty
        else fail "Missing node on Patricia descent"
      end
      else if k = n then follow child (length-k) bits else stem (n-k) path child
  | Branch (l,r) -> follow (if Z.testbit bits (length-1) then r else l) (length-1) bits
  | _ -> fail "Missing node on Patricia descent"

type commitment = Zero | Hash of Z.t | Path of edge

let lookup facts key =
  match Hashtbl.find_opt facts key with
  | Some node -> node | None -> fail "Missing Patricia preimage for %s" (Z.to_string key)

let canonical facts key =
  if Z.equal key Z.zero then Zero else
  match Hashtbl.find_opt facts key with Some (Edge edge) -> Path edge | _ -> Hash key

let children facts = function
  | Zero -> Zero, Zero
  | Hash hash ->
      (match lookup facts hash with
       | Binary (l,r) -> canonical facts l, canonical facts r
       | Edge _ -> fail "Expected binary Patricia node")
  | Path {length; path; bottom} ->
      if length = 0 then fail "Empty Patricia edge";
      let i = length - 1 in
      let child = if i = 0 then Hash bottom else Path {length=i; path=Z.extract path 0 i; bottom} in
      if Z.testbit path i then Zero, child else child, Zero

(* Number of leading update bits for which this commitment has no sibling. *)
let shared_edge bits length = function
  | Zero -> length
  | Hash _ -> 0
  | Path edge ->
      let n = min length edge.length in
      n - Z.numbits (Z.logxor (prefix bits length n) (prefix edge.path edge.length n))

let advance edge n = match edge with
  | Zero -> Zero
  | Path e when n = e.length -> Hash e.bottom
  | Path e -> Path {e with length=e.length-n; path=Z.extract e.path 0 (e.length-n)}
  | Hash _ -> assert false

let descents facts height updates prev next =
  let map = Hashtbl.create 16 in
  let rec explore start prefix h path tree old fresh =
    let save () =
      let length = start - h in
      if length > 1 then Hashtbl.add map (start,prefix) (length,Z.extract path 0 length) in
    let split () =
        let l,r = update_children tree in
        let ol,orr = children facts old and nl,nr = children facts fresh in
        let next = h-1 and left = Z.shift_left path 1 in
        let right = Z.succ left in
        if l = Empty && ol = Zero && nl = Zero then explore start prefix next right r orr nr
        else if r = Empty && orr = Zero && nr = Zero then explore start prefix next left l ol nl
        else begin
          save ();
          explore next left next left l ol nl;
          explore next right next right r orr nr
        end in
    match tree with
    | Empty -> ()
    | Leaf -> save ()
    | Branch _ -> split ()
    | Stem (length,bits,child) ->
        let n = min (shared_edge bits length old) (shared_edge bits length fresh) in
        if n = 0 then split () else
        let suffix = stem (length-n) bits child in
        let next_path = Z.logor (Z.shift_left path n) (Z.shift_right bits (length-n)) in
        explore start prefix (h-n) next_path suffix (advance old n) (advance fresh n) in
  explore height Z.zero height Z.zero updates (canonical facts prev) (canonical facts next);
  map
