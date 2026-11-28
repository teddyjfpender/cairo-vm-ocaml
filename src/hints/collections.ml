(* Array search, set membership and usort hints (cairo-vm
   find_element_hint.rs, set.rs, usort.rs). The first-occurrence index for
   find_element lives in Find_element. *)

open Errors
open Segment
open Vm
open Hintrt
module C = Hint_codes

(* A completed block records the maximum seen since row zero. These maxima
   are ordered even when the input is unsorted. A relocatable terminates any
   scan, so it never needs to be inserted into the index. *)
type lower_index = { mutable maxima : Felt.t array; mutable blocks : int }
type lower_cursor = {
  owner : vm; base : Felt.t; stride : int;
  mutable last_key : Felt.t; mutable last_index : int;
  mutable index : lower_index option;
}

let lower_block_size = 128

let search_lower cursor vm arr width length key =
  let row i = mem_at vm arr (width * i) in
  let reaches v = Felt.is_reloc v || Felt.compare v key >= 0 in
  let rec scan i =
    if i = length || reaches (row i) then i else scan (i + 1)
  in
  let indexed t =
    let rec first_block lo hi =
      if lo = hi then lo else
        let mid = lo + (hi - lo) / 2 in
        if Felt.compare t.maxima.(mid) key >= 0 then first_block lo mid
        else first_block (mid + 1) hi
    in
    let block = first_block 0 t.blocks in
    let start = min length (block * lower_block_size) in
    if block < t.blocks then scan start
    else begin
      let rec extend i maximum =
        if i = length then i else
          let v = row i in
          if reaches v then i else begin
            let maximum = if Felt.compare v maximum > 0 then v else maximum in
            let next = i + 1 in
            if next mod lower_block_size = 0 then begin
              if t.blocks = Array.length t.maxima then
                t.maxima <- Array.append t.maxima (Array.make t.blocks Felt.zero);
              t.maxima.(t.blocks) <- maximum;
              t.blocks <- t.blocks + 1
            end;
            extend next maximum
          end
      in
      extend start (if block = 0 then Felt.zero else t.maxima.(block - 1))
    end
  in
  match !cursor with
  | Some c when c.owner == vm && c.base = arr && c.stride = width ->
      let answer =
        match c.index with
        | Some t -> indexed t
        | None when Felt.compare key c.last_key >= 0 -> scan (min length c.last_index)
        | None when c.last_index < lower_block_size -> scan 0
        | None ->
            let t = {maxima = Array.make 8 Felt.zero; blocks = 0} in
            c.index <- Some t;
            indexed t
      in
      c.last_key <- key; c.last_index <- answer; answer
  | _ ->
      let answer = scan 0 in
      cursor := Some { owner = vm; base = arr; stride = width; last_key = key;
                       last_index = answer; index = None };
      answer

(* ---- set membership ---- *)

(* Cairo memory is write-once. A row whose first word has been read can
   be ruled out for any different first word, even if its suffix has holes.
   Cache the earliest row for each first word and check matching rows with
   the ordinary element comparison. Keep just one range per compiled hint. *)
let set_word_hash = Felt.hash

module Set_words = Hashtbl.Make (struct
  type t = Felt.t
  let equal = Felt.equal
  let hash = set_word_hash
end)

module Set_rows = Hashtbl.Make (struct
  type t = Felt.t array
  let equal a b = Array.length a = Array.length b && Array.for_all2 Felt.equal a b
  let hash = Array.fold_left (fun h v -> (h * 65599) lxor set_word_hash v) 0
end)

type complete_rows = { rows : int Set_rows.t; mutable next : int }

type set_index = {
  owner : vm;
  base : Felt.t;
  width : int;
  first : int Set_words.t;
  mutable composite : complete_rows option;
  mutable scanned : int; (* cell offset of the next unindexed row *)
}

let find_set_element cache vm base total elm =
  let es = Array.length elm and e0 = elm.(0) in
  let seg = Felt.rseg base and start = Felt.roff base in
  let mem = vm.segs.(seg) in
  let capacity = slen mem in
  let cell off =
    let v = sget mem off in
    if v = Felt.empty then fail "Unknown memory cell %d:%d" seg off;
    v
  in
  let index =
    if total / es < 32 then None
    else match !cache with
      | Some t when t.owner == vm && t.base = base && t.width = es -> !cache
      | _ ->
          let t = { owner = vm; base; width = es; first = Set_words.create 32; scanned = 0; composite = None } in
          cache := Some t;
          (* A single lookup pays only for the scan. Start indexing if this
             hint sees the same range again. *)
          None
  in
  let from = match index with
    | None -> 0
    | Some t -> Option.value (Set_words.find_opt t.first e0) ~default:t.scanned
  in
  let rec search collisions i =
    if i >= total then -1
    else begin
      let off = start + i in
      if off + es > capacity then fail "Unknown memory cell %d:%d" seg off;
      let v = cell off in
      (match index with
      | Some t when i = t.scanned ->
          if not (Set_words.mem t.first v) then Set_words.add t.first v i;
          t.scanned <- i + es
      | _ -> ());
      if Felt.equal v e0 then begin
        let j = ref 1 in
        while !j < es && Felt.equal (cell (off + !j)) elm.(!j) do incr j done;
        if !j = es then i / es else begin
          if collisions = 15 && es > 1 then
            (match index with
             | Some t when t.composite = None ->
                 t.composite <- Some {rows = Set_rows.create 32; next = 0}
             | _ -> ());
          search (collisions + 1) (i + es)
        end
      end else search collisions (i + es)
    end
  in
  match index with
  | Some {composite = Some t; _} ->
      (match Set_rows.find_opt t.rows elm with
       | Some i -> if i < total then i / es else -1
       | None ->
           let rec extend i =
             if i >= total then -1 else begin
               let off = start + i in
               (* A hole in an unexamined suffix is not necessarily an error.
                  Resume the ordinary short-circuit comparison at this row. *)
               let rec complete j = j = es || (sget mem (off+j) <> Felt.empty && complete (j+1)) in
               if es > capacity - off || not (complete 0) then search 0 (max i from)
               else begin
                 let row = Array.init es (fun j -> sget mem (off+j)) in
                 if not (Set_rows.mem t.rows row) then Set_rows.add t.rows row i;
                 t.next <- i + es;
                 if Array.for_all2 Felt.equal row elm then i / es else extend t.next
               end
             end
           in
           extend t.next)
  | _ -> search 0 from

let register reg =
  reg C.find_element (fun c ->
      let cache = ref None in
      fun vm ->
        let arr = get_ptr vm c "array_ptr" in
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        if es <= 0 then fail "Invalid value for elm_size.";
        let key = get_val vm c "key" in
        let n = Felt.to_nat (get_felt vm c "n_elms") in
        if n < 0 then fail "Invalid value for n_elms.";
        let index = Find_element.lookup cache vm arr es n key in
        set_val vm c "index" (Felt.small index));
  reg C.search_sorted_lower (fun c ->
      let cursor = ref None in
      fun vm ->
        let arr = get_ptr vm c "array_ptr" in
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        if es <= 0 then fail "Invalid value for elm_size.";
        let n = Felt.to_nat (get_felt vm c "n_elms") in
        if n < 0 then fail "Invalid value for n_elms.";
        let key = get_felt vm c "key" in
        let index = search_lower cursor vm arr es n key in
        set_val vm c "index" (Felt.small index));
  reg C.usort_enter_scope (fun c _ -> enter c.scopes [ ("__usort_max_size", Nothing) ]);
  reg C.usort_body (fun c vm ->
      let inp = get_ptr vm c "input" in
      let n = Felt.to_nat (get_felt vm c "input_len") in
      let pos = Felt_tbl.create 64 in
      let keys = ref [] in
      for i = 0 to n - 1 do
        let v = mem_at vm inp i in
        match Felt_tbl.find_opt pos v with
        | Some l -> Felt_tbl.replace pos v (i :: l)
        | None ->
            keys := v :: !keys;
            Felt_tbl.replace pos v [ i ]
      done;
      Felt_tbl.filter_map_inplace (fun _ l -> Some (List.rev l)) pos;
      let out = List.sort compare_values !keys in
      set c.scopes "positions_dict" (Positions pos);
      set_val vm c "output_len" (Felt.small (List.length out));
      set_val vm c "output" (gen_arg vm out);
      set_val vm c "multiplicities" (gen_arg vm (List.map (fun k -> Felt.small (List.length (Felt_tbl.find pos k))) out)));
  reg C.usort_verify (fun c vm ->
      set c.scopes "last_pos" (Int Z.zero);
      let pos = match var c.scopes "positions_dict" with Positions p -> p | _ -> fail "positions_dict missing" in
      let l = match Felt_tbl.find_opt pos (get_val vm c "value") with Some l -> l | None -> [] in
      (* h57 stores positions in increasing order. Consume that immutable list
         from the head, preserving positions_dict for subsequent lookups. *)
      set c.scopes "positions" (Ints l));
  reg C.usort_verify_multiplicity_assert (fun c _ -> match var c.scopes "positions" with Ints [] -> () | _ -> fail "assert len(positions) == 0");
  reg C.usort_verify_multiplicity_body (fun c vm ->
      let cur, rest =
        match var c.scopes "positions" with
        | Ints (cur :: rest) -> (cur, rest)
        | Ints [] -> fail "pop from empty list"
        | _ -> fail "positions"
      in
      set c.scopes "positions" (Ints rest);
      let last = Z.to_int (var_z c.scopes "last_pos") in
      set_val vm c "next_item_index" (Felt.small (cur - last));
      set c.scopes "last_pos" (Int (z (cur + 1))));
  reg C.set_add (fun c ->
      let cache = ref None in
      fun vm ->
        let es = Felt.to_nat (get_felt vm c "elm_size") in
        check (es > 0) "assert ids.elm_size > 0";
        let sp = get_ptr vm c "set_ptr" and se = get_ptr vm c "set_end_ptr" in
        check (Felt.rseg sp = Felt.rseg se && Felt.roff sp <= Felt.roff se) "assert ids.set_ptr <= ids.set_end_ptr";
        let ep = get_ptr vm c "elm_ptr" in
        let elm = Array.of_list (read_range vm ep es) in
        let found = find_set_element cache vm sp (Felt.roff se - Felt.roff sp) elm in
        if found < 0 then set_val vm c "is_elm_in_set" Felt.zero
        else begin
          set_val vm c "index" (Felt.small found);
          set_val vm c "is_elm_in_set" Felt.one
        end)
