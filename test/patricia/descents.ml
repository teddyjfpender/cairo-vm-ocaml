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

(* Compare compressed updates to an explicit binary tree, including absent
   descendants, duplicate insertions and independently diverging commitments. *)
let rec explicit tree h key =
  if h = 0 then Leaf else
  let l,r = match tree with Empty -> Empty,Empty | Branch (l,r) -> l,r | _ -> assert false in
  if Z.testbit key (h-1) then Branch (l, explicit r (h-1) key)
  else Branch (explicit l (h-1) key, r)

let () =
  let rng = Random.State.make [| 4209 |] in
  let bits h = Z.extract (Z.of_int64 (Random.State.int64 rng Int64.max_int)) 0 h in
  for h = 3 to 40 do
    let keys = List.init 12 (fun _ -> bits h) in
    let build insert = List.fold_left (fun t k -> insert t h k) Empty (keys @ keys) in
    let dense = build explicit and compact = build insert in
    let facts = Hashtbl.create 3 in
    List.iter (fun root -> Hashtbl.add facts (z root) (Edge {length=h; path=bits h; bottom=z 99})) [10;11];
    let entries t = descents facts h t (z 10) (z 11) |> Hashtbl.to_seq |> List.of_seq |> List.sort compare in
    assert (entries dense = entries compact);
    let outcome tree length word =
      try match follow tree length word with
        | Empty -> 0 | Leaf -> 1 | Branch _ | Stem _ -> 2
      with Cairovm.Errors.Vm_error _ -> 3 in
    List.iter (fun word ->
      for n = 0 to h do
        let path = if n = 0 then Z.zero else prefix word h n in
        assert (outcome dense n path = outcome compact n path)
      done) (keys @ List.init 8 (fun _ -> bits h))
  done

(* The 0.14.2 OS stores descent length through ids.siblings and writes the
   word to a separate reference. Exercise the original compiled hint spelling. *)
let () =
  let open Cairovm in
  let open Program in
  let code = "memory[ids.siblings], ids.word = descend" in
  let handlers = Hashtbl.create 32 in
  Os_patricia.register ~block:(fun () -> assert false) ~felt:(fun _ -> assert false)
    (Hashtbl.add handlers);
  let run pointer existing =
    let vm = Vm.create ~trace:false in
    for _ = 0 to 2 do ignore (Vm.add_segment vm) done;
    Vm.write vm 1 0 pointer;
    Option.iter (Vm.write vm 2 3) existing;
    let reference offset typ =
      {r_group=0; r_offset=0; r_expr=Deref (Cast (Add (Reg_fp, Int (z offset)), typ))} in
    let program = {data=[||]; builtins=[]; main=None; start=None; end_=None; hints=[];
                   references=[|reference 0 "felt**"; reference 1 "felt*"|];
                   identifiers=Hashtbl.create 0} in
    let hint = {code; scopes=["historical"]; h_group=0; h_offset=0;
                ref_ids=["historical.siblings",0; "historical.word",1]} in
    let scopes = Hintrt.new_scopes () in
    Hintrt.enter scopes ["descend_length", Hintrt.Int (z 4); "descend_word", Hintrt.Int (z 11)];
    (Hashtbl.find handlers code) (Hintrt.make_ctx program scopes hint) vm;
    assert (Felt.equal (Vm.get vm 1 0) pointer);
    assert (Felt.equal (Vm.get vm 2 3) (Felt.of_int 4));
    assert (Felt.equal (Vm.get vm 1 1) (Felt.of_int 11)) in
  let pointer = Felt.reloc 2 3 in
  run pointer None;
  run pointer (Some (Felt.of_int 4));
  let rejects pointer existing =
    match run pointer existing with
    | exception Errors.Vm_error _ -> ()
    | () -> failwith "accepted invalid sibling write" in
  rejects (Felt.of_int 3) None;
  rejects pointer (Some (Felt.of_int 5))
