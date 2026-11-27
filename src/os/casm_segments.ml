(* Contract segment boundaries refer to slices of the original class, even
   after the OS replaces the first word of an unused slice in VM memory. *)
open Errors
type t = { length : int; contents : contents }
and contents = Words of Felt.t array * int | Children of t list

let of_json words lengths =
  let data = Array.of_list words and next = ref 0 in
  let rec parse = function
    | `List items ->
        let start = !next in
        let children = List.map parse items in
        {length = !next - start; contents = Children children}
    | j ->
        let length = Pie_file.int_of_json j and start = !next in
        if length > Array.length data - start then fail "Class segment extends beyond bytecode";
        next := start + length;
        {length; contents = Words (data,start)} in
  let result = parse (if lengths = `Null then `Int (Array.length data) else lengths) in
  if !next <> Array.length data then fail "Class segments do not cover bytecode";
  result

let rec hash digest node =
  match node.contents with
  | Words (data,start) -> digest (Array.sub data start node.length |> Array.to_list)
  | Children nodes ->
      let fields = List.concat_map (fun c -> [Felt.small c.length; hash digest c]) nodes in
      Felt.add Felt.one (digest fields)
