(* The sequencer searches simultaneously through the modified leaves and the
   old and new commitment trees. Only branches containing updates are opened. *)
open Errors

type update = Empty | Leaf | Branch of update * update
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

let rec insert tree height key =
  if height = 0 then Leaf else
    let l, r = match tree with Branch (l,r) -> l,r | Empty -> Empty,Empty | Leaf -> assert false in
    let i = height - 1 in
    if Z.testbit key i then Branch (l, insert r i key) else Branch (insert l i key, r)

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

let descents facts height updates prev next =
  let map = Hashtbl.create 16 in
  let rec explore start prefix h path tree old fresh =
    let save () =
      let length = start - h in
      if length > 1 then Hashtbl.add map (start,prefix) (length,Z.extract path 0 length) in
    match tree with
    | Empty -> ()
    | Leaf -> save ()
    | Branch (l,r) ->
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
  explore height Z.zero height Z.zero updates (canonical facts prev) (canonical facts next);
  map
