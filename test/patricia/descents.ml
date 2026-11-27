open Cairovm.Patricia_tree

let z = Z.of_int
let add tree key = insert tree 4 (z key)

let () =
  let facts = Hashtbl.create 8 in
  (* Modifying leaves 0b0010 and 0b0011 shares a three-bit prefix, until an
     existing sibling at 0b0100 shortens the common descent to one step. *)
  let updates = add (add Empty 2) 3 in
  let find old next = descents facts 4 updates old next in
  let empty_roots = find Z.zero Z.zero in
  assert (Hashtbl.length empty_roots = 1);
  assert (Hashtbl.find empty_roots (4, Z.zero) = (3,z 1));
  Hashtbl.add facts (z 100) (Edge {length=4; path=z 4; bottom=z 33});
  let with_sibling = find (z 100) Z.zero in
  assert (Hashtbl.length with_sibling = 0);
  (* A branch missing from the supplied image is opened only on paths with
     modifications. *)
  Hashtbl.add facts (z 101) (Binary (Z.zero,z 99));
  let sibling_only = find (z 101) Z.zero in
  assert (Hashtbl.find sibling_only (3,Z.zero) = (2,z 1));
  assert (Hashtbl.length (descents facts 4 Empty (z 99) (z 101)) = 0)
