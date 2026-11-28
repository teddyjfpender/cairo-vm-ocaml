(* Cairo 0 hashes commit to the pinned sequencer's PythonJsonFormatter layout, including decimal
   hint-PC ordering and the attributes omitted by older compiler releases. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util

let python_string buf s =
  Buffer.add_char buf '"';
  let length = String.length s in
  let rec plain start i =
    if i = length then Buffer.add_substring buf s start (i - start)
    else match s.[i] with
      | ' '..'!' | '#'..'[' | ']'..'\127' -> plain start (i + 1)
      | ch ->
          Buffer.add_substring buf s start (i - start);
          let next = match ch with
            | '"' -> Buffer.add_string buf "\\\""; i + 1
            | '\\' -> Buffer.add_string buf "\\\\"; i + 1
            | '\b' -> Buffer.add_string buf "\\b"; i + 1
            | '\t' -> Buffer.add_string buf "\\t"; i + 1
            | '\n' -> Buffer.add_string buf "\\n"; i + 1
            | '\012' -> Buffer.add_string buf "\\f"; i + 1
            | '\r' -> Buffer.add_string buf "\\r"; i + 1
            | '\000'..'\031' -> Printf.bprintf buf "\\u%04x" (Char.code ch); i + 1
            | _ ->
                let scalar = String.get_utf_8_uchar s i in
                if not (Uchar.utf_decode_is_valid scalar) then fail "Invalid UTF-8 in class definition";
                (* The pinned sequencer pads non-ASCII UTF-16 units with spaces. *)
                let escape u = Printf.bprintf buf "\\u%4x" u in
                let u = Uchar.to_int (Uchar.utf_decode_uchar scalar) in
                if u <= 65535 then escape u else begin
                  let v = u - 65536 in
                  escape (0xd800 + (v lsr 10)); escape (0xdc00 + (v land 1023))
                end;
                i + Uchar.utf_decode_length scalar in
          plain next next
  in
  plain 0 0;
  Buffer.add_char buf '"'

let hinted_hash cls =
  let p = U.member "program" cls in
  let attributes = match U.member "attributes" p with
    | `Null | `List [] -> None
    | `List attrs -> Some (`List (List.map (fun a ->
        `Assoc (List.filter (function "accessible_scopes", `List [] | "flow_tracking_data", `Null -> false
                                      | _ -> true) (U.to_assoc a))) attrs))
    | _ -> fail "Invalid deprecated class attributes" in
  let fields = List.filter (fun (k,v) ->
      k <> "attributes" && k <> "debug_info" && (k <> "compiler_version" || v <> `Null)) (U.to_assoc p) in
  let program = ("debug_info", `Null) :: fields in
  let program = match attributes with Some a -> ("attributes",a) :: program | None -> program in
  let buf = Buffer.create 4096 in
  let seq f xs = List.iteri (fun i x -> if i > 0 then Buffer.add_string buf ", "; f x) xs in
  let rec write path = function
    | `Assoc fields ->
        Buffer.add_char buf '{';
        let numeric = path = ["hints";"program"] in
        let order (a,_) (b,_) = if numeric then compare (int_of_string a) (int_of_string b)
          else String.compare a b in
        seq (fun (k,v) -> python_string buf k; Buffer.add_string buf ": "; write (k :: path) v) (List.sort order fields);
        Buffer.add_char buf '}'
    | `List l -> Buffer.add_char buf '['; seq (write ("" :: path)) l; Buffer.add_char buf ']'
    | `String s -> python_string buf s
    | v -> Buffer.add_string buf (Yojson.Safe.to_string v) in
  write [] (`Assoc ["abi",U.member "abi" cls; "program",`Assoc program]);
  let raw = Buffer.contents buf in
  let raw =
    if U.member "compiler_version" p <> `Null then raw else
    let pairs = Str.regexp "\\([^: \t,]+\\):[ \t]*\\([^, \t)]+\\)" in
    let fix s = Str.global_replace pairs "\\1 : \\2" s in
    let fix_field s =
      let field = Str.matched_group 1 s and v = Str.matched_group 2 s in
      let v = if field = "cairo_type" && String.starts_with ~prefix:"(" v then fix v
        else if field = "value" then Str.global_substitute (Str.regexp "([^()]+)") (fun s -> fix (Str.matched_string s)) v
        else v in
      "\"" ^ field ^ "\": \"" ^ v ^ "\"" in
    Str.global_substitute (Str.regexp "\"\\(cairo_type\\|value\\)\": \"\\([^\"]*\\)\"") fix_field raw in
  let digest = Keccak.keccak256 (Bytes.of_string raw) in
  Felt.of_z (Z.extract (z_of_be (Bytes.unsafe_to_string digest)) 0 250)

module Prepared : sig
  type t
  val start : Yojson.Safe.t -> t option
  val finish : t -> unit
  val install : t -> string -> bool option
end = struct
  type t = string * bytes option Lazy.t
  external compute : bytes -> bool = "cvm_compute_pedersen_chain"
  external install_computed : bytes -> bool = "cvm_install_pedersen_chain" [@@noalloc]

  (* Only materialize a bounded chain worth computing concurrently with loading
     the OS program. The ordinary class loader validates every field as usual. *)
  let start classes =
    if Sys.big_endian then None else
    try
      let select best (hash, cls) =
        match U.member "data" (U.member "program" cls) with
        | `List words ->
            let n = List.length words in
            if n >= 256 && n <= 8192 && n > fst best then n, Some (hash, words) else best
        | _ -> best in
      let len, selected = List.fold_left select (0, None) (U.to_assoc classes) in
      Option.map (fun (hash, words) ->
          let packed = Bytes.make (64 * len) '\000' in
          List.iteri (fun i -> function
              | `String w when String.length w <= 80 ->
                  let z = Z.of_string w in
                  if Z.sign z < 0 || Z.geq z Felt.p then raise Exit;
                  let bits = Z.to_bits z in
                  Bytes.blit_string bits 0 packed (64 * i) (String.length bits)
              | _ -> raise Exit) words;
          let task = Domain.spawn (fun () -> if compute packed then Some packed else None) in
          hash, lazy (Domain.join task)) selected
    with Exit | Invalid_argument _ | Failure _ | Yojson.Safe.Util.Type_error _ -> None

  let finish (_, chain) = ignore (Lazy.force chain)

  let install (key, chain) hash =
    if String.equal key hash then Option.map install_computed (Lazy.force chain) else None
end

external restore_cache : bool -> bool = "cvm_batch_pedersen_cache" [@@noalloc]

(* Historical class definitions encode absent attributes as either missing or null. *)
let load_program json =
  let fields = U.to_assoc json in
  let normalize = function "attributes", `Null -> "attributes", `List [] | field -> field in
  Program.load_json (`Assoc (List.map normalize fields))

let register ?prepared ~classes ~felt ~compile reg =
  let remaining = ref [] and loaded = ref None and previous_cache = ref None in
  reg "LoadDeprecatedClassFacts" (fun c vm ->
      remaining := List.sort (fun (a,_) (b,_) -> Z.compare (Z.of_string a) (Z.of_string b)) classes;
      set_val vm c "n_compiled_class_facts" (Felt.small (List.length classes));
      enter c.scopes []);
  reg "LoadDeprecatedClassInner" (fun c vm ->
      match !remaining with
      | [] -> fail "End of deprecated class iterator"
      | (hash,j) :: rest ->
          remaining := rest;
          let base = Felt.reloc (Vm.add_segment vm) 0 in
          let entries kind =
            let ep = U.member kind (U.member "entry_points_by_type" j) in
            let rows = if ep = `Null then [] else U.to_list ep in
            let values = List.concat_map (fun row -> [felt (U.member "selector" row); felt (U.member "offset" row)]) rows in
            [Felt.small (List.length rows); gen_arg vm values] in
          let external_ = entries "EXTERNAL" in
          let l1 = entries "L1_HANDLER" in
          let ctor = entries "CONSTRUCTOR" in
          let p = load_program (U.member "program" j) in
          let names = gen_arg vm (List.map Os_block_hash.ascii p.builtins) in
          let code = gen_arg vm (Array.to_list (Array.map Felt.of_z p.data)) in
          write_arg vm base ([Felt.of_z (const_z c "DEPRECATED_COMPILED_CLASS_VERSION")] @ external_ @ l1 @ ctor
            @ [Felt.small (List.length p.builtins); names; hinted_hash j; Felt.small (Array.length p.data); code]);
          previous_cache := Option.bind prepared (fun pending -> Prepared.install pending hash);
          loaded := Some (felt (`String hash), p, code);
          set_val vm c "compiled_class" base);
  reg "LoadDeprecatedClass" (fun c vm ->
      match !loaded with
      | None -> fail "Missing deprecated class"
      | Some (hash, p, code) ->
          Option.iter (fun mode -> ignore (restore_cache mode)) !previous_cache;
          previous_cache := None;
          if not (Felt.equal hash (get_member vm c "compiled_class_fact" ["hash"])) then
            fail "Inconsistent deprecated class hash";
          List.iter (fun (pc,hints) ->
              Cpu.register_runtime_hints vm ~segment:(Felt.rseg code) ~pc
                (Array.of_list (List.map (compile p c.scopes) hints))) p.hints;
          loaded := None)
