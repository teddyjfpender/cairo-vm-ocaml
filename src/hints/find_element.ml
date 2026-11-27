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
  (* Only moving windows need later occurrences. A fixed table keeps one
     integer per distinct key, regardless of the number of duplicates. *)
  later : int Queue.t Words.t option;
  mutable window : int;
  mutable scanned : int;
  mutable initial_span : int;
}

let make_index owner base width later =
  { owner; base; width; first = Words.create 1; later; window = 0; scanned = 0; initial_span = 0 }

let remember t v i =
  if not (Words.mem t.first v) then Words.add t.first v i
  else match t.later with
    | None -> ()
    | Some positions ->
        let q = match Words.find_opt positions v with
          | Some q -> q
          | None -> let q = Queue.create () in Words.add positions v q; q
        in
        Queue.add i q

(* These rows were read successfully while extending the index. Retire
   each occurrence once, so long-running small windows release old keys. *)
let advance t positions start =
  for i = t.window to start - 1 do
    let key = Hintrt.mem_at t.owner t.base (i * t.width) in
    match Words.find_opt positions key with
    | None -> Words.remove t.first key
    | Some q ->
        Words.replace t.first key (Queue.take q);
        if Queue.is_empty q then Words.remove positions key
  done;
  t.window <- start

let lookup cache vm base width length key =
  let missing () = Errors.fail "Key %s was not found." (Vm.value_to_string key) in
  let search t =
    match Words.find_opt t.first key with
    | Some i -> let relative = i - t.window in if relative < length then relative else missing ()
    | None ->
        let rec extend i =
          let relative = i - t.window in
          if relative >= length then missing ();
          let v = Hintrt.mem_at vm base (width * relative) in
          remember t v i;
          t.scanned <- i + 1;
          if Felt.equal v key then relative else extend (i + 1)
        in
        extend t.scanned
  in
  let cold () =
    let t = make_index vm base width None in
    cache := Some t;
    let rec scan i =
      if i >= length then begin t.initial_span <- i; missing () end;
      let v = Hintrt.mem_at vm base (width * i) in
      if Felt.equal v key then begin t.initial_span <- i + 1; i end else scan (i + 1)
    in
    scan 0
  in
  match !cache with
  | Some t when t.owner == vm && t.width = width && Felt.rseg t.base = Felt.rseg base ->
      let delta = Felt.roff base - Felt.roff t.base in
      if delta = 0 && t.window = 0 then search t
      else if delta < 0 || delta mod width <> 0 then cold ()
      else begin
        let start = delta / width in
        if start < t.window || start > max t.scanned t.initial_span then cold ()
        else match t.later with
          | Some positions -> advance t positions start; search t
          | None ->
              (* Rebuild once at the first forward shift. Earlier fixed-base
                 queries deliberately did not retain duplicate occurrences. *)
              let moving = make_index vm base width (Some (Words.create 1)) in
              cache := Some moving;
              search moving
      end
  | _ -> cold ()
