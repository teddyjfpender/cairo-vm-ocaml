(* Incremental first-occurrence index for one compiled find_element hint. *)
module Words = Hashtbl.Make (struct
  type t = int
  let equal = Felt.equal
  let hash v = if Felt.is_big v then Z.hash (Felt.to_z v) else Hashtbl.hash v
end)

type index = {
  owner : Vm.vm;
  base : int;
  width : int;
  first : int Words.t;
  mutable scanned : int;
}

let lookup cache vm base width length key =
  let missing () = Vm.fail "Key %s was not found." (Vm.value_to_string key) in
  let read i = Hintrt.mem_at vm base (width * i) in
  match !cache with
  | Some t when t.owner == vm && base = t.base && width = t.width ->
      (match Words.find_opt t.first key with
       | Some i -> if i < length then i else missing ()
       | None ->
           (* Index only cells actually visited. An unknown cell stops this
              query at the same row as a fresh scan. *)
           let rec extend i =
             if i >= length then missing ();
             let v = read i in
             if not (Words.mem t.first v) then Words.add t.first v i;
             t.scanned <- i + 1;
             if Felt.equal v key then i else extend (i + 1)
           in
           extend t.scanned)
  | _ ->
      (* A one-off lookup uses the plain scan. Keep one range per hint. *)
      cache := Some {owner = vm; base; width; first = Words.create 1; scanned = 0};
      let rec scan i =
        if i >= length then missing ();
        if Felt.equal (read i) key then i else scan (i + 1)
      in
      scan 0
