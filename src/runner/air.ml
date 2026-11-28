open Errors
open Builtin
open Vm

(* ---- minimal serde_json-compatible pretty printer ---- *)

type json = Obj of (string * json) list | Arr of json list | Str of string | Int of int | Null

let escape b s =
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"'

let rec pp b ind = function
  | Null -> Buffer.add_string b "null"
  | Int n -> Buffer.add_string b (string_of_int n)
  | Str s -> escape b s
  | Arr [] -> Buffer.add_string b "[]"
  | Obj [] -> Buffer.add_string b "{}"
  | Arr l ->
      Buffer.add_string b "[\n";
      List.iteri
        (fun i v ->
          if i > 0 then Buffer.add_string b ",\n";
          Buffer.add_string b (String.make (ind + 2) ' ');
          pp b (ind + 2) v)
        l;
      Buffer.add_char b '\n';
      Buffer.add_string b (String.make ind ' ');
      Buffer.add_char b ']'
  | Obj l ->
      Buffer.add_string b "{\n";
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_string b ",\n";
          Buffer.add_string b (String.make (ind + 2) ' ');
          escape b k;
          Buffer.add_string b ": ";
          pp b (ind + 2) v)
        l;
      Buffer.add_char b '\n';
      Buffer.add_string b (String.make ind ' ');
      Buffer.add_char b '}'

let to_string j =
  let b = Buffer.create 65536 in
  pp b 0 j;
  Buffer.contents b

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc

let hex_z z = "0x" ^ Z.format "%x" z
let hex_felt v = Str (hex_z (Felt.to_z v))

(* ---- public input ---- *)

(* Relocated value of a cell, as cairo-vm's relocated memory holds it. *)
let relocated_value table v =
  if v = Felt.empty then Null
  else if Felt.is_reloc v then Str (hex_z (Z.of_int (table.(Felt.rseg v) + Felt.roff v)))
  else hex_felt v

let public_input (r : Runner.t) =
  if not r.proof then fail "AIR public input requires proof mode";
  let vm = r.vm in
  let table = Artifacts.relocation_table r in
  (* cairo-vm's relocated memory: length grows by one per empty cell and to
     cover every assigned relocated address *)
  let mem_len = ref 1 in
  for s = 0 to vm.nsegs - 1 do
    for o = 0 to used_size vm s - 1 do
      if read vm s o <> Felt.empty then mem_len := max !mem_len (table.(s) + o + 1) else incr mem_len
    done
  done;
  (* reverse map relocated address -> (segment, offset) for public cells *)
  let value_at addr seg off =
    if addr >= !mem_len then fail "The provided memory doesn't contain public address %d" addr;
    relocated_value table (read vm seg off)
  in
  let public_memory =
    List.concat
      (List.init vm.nsegs (fun s ->
           match Hashtbl.find_opt r.public_offsets s with
           | None -> []
           | Some offs ->
               List.map
                 (fun (o, page) ->
                   let addr = table.(s) + o in
                   Obj [ ("address", Int addr); ("value", value_at addr s o); ("page", Int page) ])
                 offs))
  in
  let rc_min, rc_max =
    match Resources.perm_range_check_limits r with Some x -> x | None -> fail "Range check values are missing"
  in
  let first, last = match Artifacts.trace_bounds r with Some x -> x | None -> fail "The trace slice provided is empty" in
  let reloc_pc (s, pc, _, _) = table.(s) + pc and reloc_ap (_, _, ap, _) = table.(1) + ap in
  let seg_addr name a b = (name, Obj [ ("begin_addr", Int a); ("stop_ptr", Int b) ]) in
  let builtin_segs =
    List.map
      (fun b ->
        let stop =
          if List.mem b.kind r.prog_builtins then (
            if b.stop_ptr < 0 then fail "No stop pointer found for builtin %s" (bname b.kind);
            b.stop_ptr)
          else max 0 b.stop_ptr
        in
        seg_addr (bname b.kind) table.(b.base) (table.(b.base) + stop))
      vm.builtins
  in
  (* cairo-vm serializes this map from a HashMap: its key order is random *)
  let segments =
    builtin_segs
    @ [ seg_addr "program" (reloc_pc first) (reloc_pc last); seg_addr "execution" (reloc_ap first) (reloc_ap last) ]
  in
  Obj
    [
      ("layout", Str (Resources.the_layout r).name);
      ("rc_min", Int rc_min);
      ("rc_max", Int rc_max);
      ("n_steps", Int vm.steps);
      ("memory_segments", Obj segments);
      ("public_memory", Arr public_memory);
      ("dynamic_params", Null);
    ]

let write_public_input r path = write_file path (to_string (public_input r))

(* ---- private input ---- *)

let int_cell vm seg off =
  let v = read vm seg off in
  if v <> Felt.empty && Felt.is_felt v then Some v else None

(* ModBuiltinRunner::air_private_input: missing values default to 0 *)
let mod_private_input (r : Runner.t) b =
  let vm = r.vm in
  let table = Artifacts.relocation_table r in
  let cell (sg, o) = if sg >= 0 && sg < vm.nsegs && o >= 0 then read vm sg o else Felt.empty in
  let int_or0 a = let v = cell a in if v <> Felt.empty && Felt.is_felt v then v else Felt.zero in
  let reloc_or0 a = let v = cell a in if v <> Felt.empty && Felt.is_reloc v then (Felt.rseg v, Felt.roff v) else (0, 0) in
  let usize_or0 a =
    let v = cell a in
    if v <> Felt.empty && Felt.is_felt v then (let n = Felt.to_nat v in if n < 0 then 0 else n) else 0
  in
  let relocate (sg, o) = if sg < Array.length table then table.(sg) + o else 0 in
  let base = b.base in
  let n_inst = used_size vm base / 7 in
  let instances =
    List.init n_inst (fun inst ->
        let a0 = inst * 7 in
        let values_ptr = reloc_or0 (base, a0 + 4) and offsets_ptr = reloc_or0 (base, a0 + 5) in
        let n = usize_or0 (base, a0 + 6) in
        let p = List.init 4 (fun i -> (Printf.sprintf "p%d" i, hex_felt (int_or0 (base, a0 + i)))) in
        let fetch var idx =
          let off = usize_or0 (fst offsets_ptr, snd offsets_ptr + (3 * idx) + var) in
          let words = List.init 4 (fun i -> hex_felt (int_or0 (fst values_ptr, snd values_ptr + off + i))) in
          (off, words)
        in
        let batch =
          List.init 1 (fun idx ->
              let vars =
                List.concat_map
                  (fun (var, name) ->
                    let off, words = fetch var idx in
                    ((name ^ "_offset"), Int off) :: List.mapi (fun i w -> (Printf.sprintf "%s%d" name i, w)) words)
                  [ (0, "a"); (1, "b"); (2, "c") ]
              in
              Obj vars)
        in
        Obj
          ((("index", Int inst) :: p)
          @ [ ("values_ptr", Int (relocate values_ptr)); ("offsets_ptr", Int (relocate offsets_ptr)); ("n", Int n);
              ("batch", Arr batch) ]))
  in
  let zero = if r.zero_seg >= 0 && r.zero_seg < Array.length table then table.(r.zero_seg) else 0 in
  Obj [ ("instances", Arr instances); ("zero_value_address", Int zero) ]

let ecdsa_private_input (r : Runner.t) b =
  let vm = r.vm in
      (* signatures recorded by the verify_ecdsa_signature hints, ordered by
         instance index *)
      let sigs = Builtins_ext.segment_signatures vm b.base in
      let sigs = List.stable_sort (fun (a, _) (b, _) -> compare (a / 2) (b / 2)) (List.sort compare sigs) in
      List.filter_map
        (fun (off, (r_, s_)) ->
          match (int_cell vm b.base off, int_cell vm b.base (off + 1)) with
          | Some pk, Some msg ->
              let w = try Z.invert s_ Builtins_ext.ec_order with _ -> Z.zero in
              let w = Z.erem w Felt.p in
              Some
                (Obj
                   [ ("index", Int (off / 2)); ("pubkey", hex_felt pk); ("msg", hex_felt msg);
                     ("signature_input", Obj [ ("r", Str (hex_z (Z.erem r_ Felt.p))); ("w", Str (hex_z w)) ]) ])
          | _ -> None)
        sigs

external hex_into : Felt.pool -> (int[@untagged]) -> bytes -> (int[@untagged])
  = "cvm_hex_felt_byte" "cvm_hex_felt" [@@noalloc]

(* The common builtin arrays can contain millions of instances. Write each
   row to a bounded buffer while preserving serde_json's field order. *)
let write_instances oc buf vm b fields =
  let width = cells_per_instance b.kind and n = used_size vm b.base in
  let digits = Bytes.create 66 and first = ref true in
  let fields = Array.map (fun (name, index) -> ",\n      \"" ^ name ^ "\": \"", index) fields in
  Buffer.add_char buf '[';
  for instance = 0 to Resources.div_ceil n width - 1 do
    let base = instance * width in
    if Array.for_all (fun (_, i) -> Felt.is_felt (read vm b.base (base + i))) fields then begin
      Buffer.add_string buf (if !first then "\n" else ",\n");
      first := false;
      Buffer.add_string buf "    {\n      \"index\": ";
      Buffer.add_string buf (string_of_int instance);
      Array.iter (fun (prefix, i) ->
          Buffer.add_string buf prefix;
          let v = read vm b.base (base + i) in
          let len = hex_into Felt.pool (v :> int) digits in
          Buffer.add_subbytes buf digits 0 len;
          Buffer.add_char buf '"') fields;
      Buffer.add_string buf "\n    }";
      if Buffer.length buf >= 65536 then (Buffer.output_buffer oc buf; Buffer.clear buf)
    end
  done;
  if not !first then Buffer.add_string buf "\n  ";
  Buffer.add_char buf ']'

let write_private_input (r : Runner.t) ~trace_path ~memory_path path =
  if not r.proof then fail "AIR private input requires proof mode";
  let canon p = try Unix.realpath p with Unix.Unix_error _ -> p in
  let order = [ Pedersen; Range_check; Range_check96; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Add_mod; Mul_mod ] in
  Out_channel.with_open_bin path (fun oc ->
      let buf = Buffer.create 65536 in
      Buffer.add_string buf "{\n  \"trace_path\": ";
      escape buf (canon trace_path);
      Buffer.add_string buf ",\n  \"memory_path\": ";
      escape buf (canon memory_path);
      List.iter (fun k ->
          match List.find_opt (fun b -> b.kind = k) r.vm.builtins with
          | None -> ()
          | Some b ->
              Buffer.add_string buf (",\n  \"" ^ bname k ^ "\": ");
              let rows = write_instances oc buf r.vm b in
              match k with
              | Pedersen | Bitwise -> rows [|"x", 0; "y", 1|]
              | Range_check | Range_check96 -> rows [|"value", 0|]
              | Ec_op -> rows [|"p_x", 0; "p_y", 1; "m", 4; "q_x", 2; "q_y", 3|]
              | Poseidon -> rows [|"input_s0", 0; "input_s1", 1; "input_s2", 2|]
              | Keccak -> rows (Array.init 8 (fun i -> Printf.sprintf "input_s%d" i, i))
              | Ecdsa -> pp buf 2 (Arr (ecdsa_private_input r b))
              | Add_mod | Mul_mod -> pp buf 2 (mod_private_input r b)
              | Output -> assert false) order;
      Buffer.add_string buf "\n}";
      Buffer.output_buffer oc buf)
