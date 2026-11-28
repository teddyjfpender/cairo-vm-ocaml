(* Starknet CompiledClassFact, CompiledClass and entry-point tables.
   Allocate in the same order as the sequencer's LoadCairoObject. *)
open Errors
module U = Yojson.Safe.Util

let segment vm = Felt.reloc (Vm.add_segment vm) 0
let at ptr offset = Vm.reloc_add_felt ptr (Felt.small offset)

let load ?(encoded=false) ~source ~watch ~rng ~syscall vm ctx ~felt ~class_hash ~fact ~builtin_costs j =
  let compiled = segment vm in
  let entry_points = U.member "entry_points_by_type" j in
  let load_entries kind =
    let entries = U.to_list (U.member kind entry_points) in
    let table = segment vm in
    List.iteri (fun i entry ->
        let builtins = U.to_list (U.member "builtins" entry) in
        let names = List.map (fun name ->
            Felt.of_z (Hintrt.z_of_be (U.to_string name))) builtins in
        let list = Hintrt.gen_arg vm names in
        Hintrt.write_arg vm (at table (4*i))
          [felt (U.member "selector" entry); felt (U.member "offset" entry);
           Felt.small (List.length names); list]) entries;
    [Felt.small (List.length entries); table]
  in
  let external_ = load_entries "EXTERNAL" in
  let l1 = load_entries "L1_HANDLER" in
  let constructor = load_entries "CONSTRUCTOR" in
  let bytecode = U.member "bytecode" j in
  let words = match source, bytecode with
    | Some src, `List [`Int first; `Int last] ->
        Os_input.decode_words src (first, last)
    | None, `String raw when encoded -> Os_input.decode_words raw (0, String.length raw)
    | _ -> Array.of_list (List.map felt (U.to_list bytecode)) in
  let code = segment vm in
  Array.iteri (Vm.write_checked vm (Felt.rseg code)) words;
  let length = Array.length words in
  if watch then Vm.watch_segment vm (Felt.rseg code) length;
  let name = "starkware.starknet.core.os.contract_class.compiled_class_struct.COMPILED_CLASS_VERSION" in
  let version = match Hashtbl.find_opt ctx.Hintrt.prog.Program.identifiers name with
    | Some {i_value = Some v; _} -> Felt.of_z v
    | _ -> fail "Missing compiled class version in OS program" in
  Hintrt.write_arg vm compiled ([version] @ external_ @ l1 @ constructor @ [Felt.small length; code]);
  Hintrt.write_arg vm fact [class_hash; compiled];
  Hintrt.write_arg vm (at code length) [Felt.of_z (Z.of_string "0x208b7fff7fff7ffe"); builtin_costs];
  List.iter (function
    | `List [pc; `List hints] ->
        let offset = Pie_file.int_of_json pc in
        if offset >= length then fail "CASM hint beyond class bytecode";
        Cpu.register_runtime_hints vm ~segment:(Felt.rseg code) ~pc:offset
          (Array.of_list (List.map (Casm_hints.compile ~rng ~syscall ctx.scopes) hints))
    | _ -> fail "Invalid CASM hint table") (U.to_list (U.member "hints" j));
  Casm_segments.of_json words (U.member "bytecode_segment_lengths" j)
