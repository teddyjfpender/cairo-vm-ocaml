(* Hint processor for the sequencer's compiled aggregator/main.cairo. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

external word_count : string -> int = "cvm_hex_array_count" [@@noalloc]
external decode_hex : Felt.pool -> string -> Felt.t array -> int -> int = "cvm_hex_array_parse" [@@noalloc]

(* A failed speculative decode leaves the pool cursor unchanged. The general
   JSON reader handles escaped strings, decimal words and empty arrays. *)
let decode_input raw =
  let fallback () =
    Array.of_list (List.map Os_hints.felt (U.to_list (Json_reader.from_string raw))) in
  let count = word_count raw in
  if count = 0 || count > 4 * 1024 * 1024 then fallback ()
  else
    let words = Array.make count Felt.zero in
    let next = decode_hex Felt.pool raw words !(Felt.pool_n) in
    if next < 0 then fallback () else begin
      Felt.pool_n := next;
      words
    end

let initialize ?layout_def ?on_da ~proof ~path cfg prog =
  let input = Json_reader.from_file ~projection:(Fields ["bootloader_output", Encoded]) path in
  let member name = U.member name input in
  let felt = Os_hints.felt in
  let bootloader_output = ref (Some (member "bootloader_output")) in
  ignore (U.to_bool (member "debug_mode"));
  let full = U.to_bool (member "full_output") in
  let blob = match member "da" with
    | `String "CallData" -> false
    | `Assoc ["Blob", `String _] -> true
    | _ -> fail "Unknown aggregator data availability mode" in
  let chain_id = felt (member "chain_id") and fee = felt (member "fee_token_address") in
  let keys = match member "public_keys" with `Null -> [] | xs -> List.map felt (U.to_list xs) in
  let handlers = Hashtbl.create 32 in
  let reg = Hashtbl.replace handlers in
  let runner = ref None and pages_enabled = ref false in
  let set_pages pages attributes =
    let r = Option.get !runner in
    r.Runner.output_pages <- pages; r.output_attributes <- attributes in
  let captured = ref None in
  let capture = Option.map (fun _ vm base n ->
      if Option.is_some !captured then fail "Aggregator DA segment already set";
      captured := Some (Array.init n (mem_at vm base))) on_da in
  Os_da.register ~pages_enabled ~set_pages reg;
  Os_kzg.register ?capture reg;
  Os_builtins.register reg;
  ignore (Os_compression.register_squashing ~state_initialized:(fun () -> false) reg);
  reg Hint_codes.relocate_segment (Segments.relocate ~allow_felt:true);
  reg "SetStateUpdatePointersToNone" (fun _ _ -> ());
  reg "UpdateClassesPtr" (fun _ _ -> ());
  reg "GuessClassesPtr" (fun c vm -> set_val vm c "squashed_dict" (Felt.reloc (Vm.add_segment vm) 0));
  reg "GetOsOuputForInnerBlocks" (fun c vm ->
      match !bootloader_output with
      | None -> fail "Aggregator bootloader input already consumed"
      | Some words ->
          bootloader_output := None;
          Aggregator_output.load vm c (decode_input (U.to_string words)));
  reg "GetUseKzgDaAndFullOutputFromInput" (fun c vm ->
      set_val vm c "use_kzg_da" (of_bool blob);
      set_val vm c "full_output" (of_bool full));
  reg "GetPublicKeys" (fun c vm ->
      set_val vm c "public_keys" (gen_arg vm keys);
      set_val vm c "n_public_keys" (Felt.small (List.length keys)));
  reg "GetChainIdAndFeeTokenAddressFromInput" (fun c vm ->
      set_val vm c "chain_id" chain_id;
      set_val vm c "fee_token_address" fee);
  reg "DisableDaPageCreation" (fun _ _ -> pages_enabled := false);
  reg "GetAggregatorOutput" (fun _ _ -> pages_enabled := true);
  reg "WriteDaSegment" (fun _ _ ->
      if blob then Option.iter (fun save -> save (Option.get !captured)) on_da);
  let compile_hint p scopes (h : Program.hint) =
    match Hashtbl.find_opt handlers h.code with
    | Some f -> f (make_ctx p scopes h)
    | None -> Hints.compile p scopes h in
  let r = Runner.initialize ?layout_def ~compile_hint ~proof cfg prog in
  runner := Some r;
  r
