(* AIR public and private inputs (cairo-vm v3.2.0 air_public_input.rs,
   air_private_input.rs), serialized like serde_json::to_string_pretty. *)

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
  if v = 0 then Null
  else if Felt.is_reloc v then Str (hex_z (Z.of_int (table.(Felt.rseg v) + Felt.roff v)))
  else hex_felt v

let public_input (r : Runner.t) =
  if not r.proof then fail "AIR public input requires proof mode";
  let vm = r.vm in
  let table = Runner.relocation_table r in
  (* cairo-vm's relocated memory: length grows by one per empty cell and to
     cover every assigned relocated address *)
  let mem_len = ref 1 in
  for s = 0 to vm.nsegs - 1 do
    for o = 0 to used_size vm s - 1 do
      if read vm s o <> 0 then mem_len := max !mem_len (table.(s) + o + 1) else incr mem_len
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
    match Runner.perm_range_check_limits r with Some x -> x | None -> fail "Range check values are missing"
  in
  let first, last = match Runner.trace_bounds r with Some x -> x | None -> fail "The trace slice provided is empty" in
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
      ("layout", Str (Runner.the_layout r).name);
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
  if v <> 0 && Felt.is_felt v then Some v else None

let instances vm b fields =
  let cpi = cells_per_instance b.kind in
  let n = used_size vm b.base in
  let out = ref [] in
  let idx = ref 0 and off = ref 0 in
  while !off < n do
    let vals = List.mapi (fun i _ -> int_cell vm b.base (!off + i)) fields in
    if List.for_all Option.is_some vals then
      out := Obj (("index", Int !idx) :: List.map2 (fun name v -> (name, hex_felt (Option.get v))) fields vals) :: !out;
    incr idx;
    off := !off + cpi
  done;
  List.rev !out

let builtin_private_input (r : Runner.t) b =
  let vm = r.vm in
  match b.kind with
  | Range_check | Range_check96 ->
      List.filter_map
        (fun o -> Option.map (fun v -> Obj [ ("index", Int o); ("value", hex_felt v) ]) (int_cell vm b.base o))
        (List.init (used_size vm b.base) Fun.id)
  | Pedersen | Bitwise -> instances vm b [ "x"; "y" ]
  | Ec_op ->
      (* memory order p_x, p_y, q_x, q_y, m; serialized as p_x, p_y, m, q_x, q_y *)
      List.map
        (function
          | Obj [ i; px; py; qx; qy; m ] -> Obj [ i; px; py; ("m", snd m); ("q_x", snd qx); ("q_y", snd qy) ]
          | j -> j)
        (instances vm b [ "p_x"; "p_y"; "q_x"; "q_y"; "m" ])
  | Poseidon -> instances vm b [ "input_s0"; "input_s1"; "input_s2" ]
  | Keccak -> instances vm b (List.init 8 (Printf.sprintf "input_s%d"))
  | Ecdsa ->
      (* signatures come from hints; this VM rejects the ecdsa builtin when used *)
      if used_size vm b.base > 0 then fail "ecdsa private input is not supported";
      []
  | Add_mod | Mul_mod -> fail "mod builtin private input is not supported"
  | Output -> []

let private_input (r : Runner.t) ~trace_path ~memory_path =
  if not r.proof then fail "AIR private input requires proof mode";
  let canon p = try Unix.realpath p with Unix.Unix_error _ -> p in
  let order = [ Pedersen; Range_check; Range_check96; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon ] in
  let fields =
    List.filter_map
      (fun k ->
        match List.find_opt (fun b -> b.kind = k) r.vm.builtins with
        | Some b -> Some (bname k, Arr (builtin_private_input r b))
        | None -> None)
      order
  in
  Obj ((("trace_path", Str (canon trace_path)) :: ("memory_path", Str (canon memory_path)) :: fields))

let write_private_input r ~trace_path ~memory_path path =
  write_file path (to_string (private_input r ~trace_path ~memory_path))
