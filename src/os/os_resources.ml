(* The sequencer snapshots builtin pointers at transaction and syscall boundaries.
   A missing proof-layout builtin is represented by a felt zero, so accepting an
   arbitrary cell here would also accept executions rejected by the OS logger. *)
open Errors
open Hintrt

let builtin_offsets program =
  let members name =
    let key = "starkware.starknet.core.os.builtins." ^ name in
    match Hashtbl.find_opt program.Program.identifiers key with
    | Some {Program.i_type="struct"; i_members; _} -> i_members
    | _ -> fail "Missing OS builtin struct %s" key in
  let parent = members "BuiltinPointers" in
  let group field typ =
    let base = match List.assoc_opt field parent with
      | Some off -> off | None -> fail "Missing builtin pointer group %s" field in
    List.filter_map (fun (name, off) -> match name with
        | "segment_arena" | "sha256" | "sha512" -> None
        | _ -> Some (base + off)) (members typ) in
  Array.of_list (group "selectable" "SelectableBuiltins" @
                 group "non_selectable" "NonSelectableBuiltins")

let snapshot offsets ctx vm =
  let range_check = get_ptr vm ctx "range_check_ptr" in
  let ptr = get_ptr vm ctx "builtin_ptrs" in
  let values = Array.map (fun off ->
      let v = mem_at vm ptr off in
      if not (Felt.is_reloc v) then
        fail "Expected relocatable at address %d:%d" (Felt.rseg ptr) (Felt.roff ptr + off);
      v) (Lazy.force offsets) in
  range_check, values

let check_progress (first_range, first) (last_range, last) =
  let check a b =
    if Felt.rseg a <> Felt.rseg b || Felt.roff a > Felt.roff b then
      fail "OS resource pointer moved backwards or changed segments" in
  check first_range last_range;
  Array.iteri (fun i a -> check a last.(i)) first
