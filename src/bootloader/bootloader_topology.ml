open Errors

let of_pie pie size =
  match List.assoc_opt "output" pie.Pie_file.additional with
  | None -> [1; 0], [0]
  | Some data ->
      let pages, attributes = Pie_run.output_data data in
      let tree = match List.assoc_opt "gps_fact_topology" attributes with
        | Some tree when List.length tree <= 10 && List.length tree mod 2 = 0
                         && List.for_all (fun n -> n >= 0 && n <= 1 lsl 30) tree -> tree
        | None when pages = [] -> [1; 0]
        | _ -> fail "Invalid task fact topology" in
      let first = match pages with [] -> size | (_, (start, _)) :: _ -> start in
      let next = ref first in
      let sizes = List.mapi (fun i (id, (offset, length)) ->
          if id <> i + 1 || offset <> !next || offset > size || length > size - offset then
            fail "Invalid task output page";
          next := offset + length; length) pages in
      if !next <> size then fail "Task pages do not cover output";
      tree, first :: sizes

let pages topologies =
  let id = ref 0 and offset = ref 1 in
  List.concat_map (fun (_, sizes) ->
      offset := !offset + 2;
      List.map (fun size ->
          incr id;
          let start = !offset in offset := start + size;
          !id, (start, size)) sizes) topologies

let write path topologies =
  let ints l = `List (List.map (fun n -> `Int n) l) in
  let topology (tree, sizes) = `Assoc ["tree_structure", ints tree; "page_sizes", ints sizes] in
  Out_channel.with_open_bin path (fun out ->
      Yojson.Safe.to_channel out (`Assoc ["fact_topologies", `List (List.map topology topologies)]))
