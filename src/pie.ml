(* Cairo PIE output (cairo-vm v3.2.0 vm/src/vm/runners/cairo_pie.rs and
   CairoRunner::get_cairo_pie; unchanged in v4.0.0). The archive holds the same five members with
   the same contents as cairo-vm's; entries are stored uncompressed, so the
   zip container bytes differ from cairo-vm's deflated archive. *)

open Vm

(* ---- compact serde_json output ---- *)

type json = Obj of (string * json) list | Arr of json list | Str of string | Num of string | Null

let rec emit b = function
  | Null -> Buffer.add_string b "null"
  | Num s -> Buffer.add_string b s
  | Str s ->
      Buffer.add_char b '"';
      String.iter
        (fun c ->
          match c with
          | '"' -> Buffer.add_string b "\\\""
          | '\\' -> Buffer.add_string b "\\\\"
          | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
          | c -> Buffer.add_char b c)
        s;
      Buffer.add_char b '"'
  | Arr l ->
      Buffer.add_char b '[';
      List.iteri (fun i v -> if i > 0 then Buffer.add_char b ','; emit b v) l;
      Buffer.add_char b ']'
  | Obj l ->
      Buffer.add_char b '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char b ',';
          emit b (Str k);
          Buffer.add_char b ':';
          emit b v)
        l;
      Buffer.add_char b '}'

let to_string j =
  let b = Buffer.create 4096 in
  emit b j;
  Buffer.contents b

let int n = Num (string_of_int n)

(* ---- zip (stored entries) ---- *)

let crc_table =
  Array.init 256 (fun n ->
      let c = ref n in
      for _ = 0 to 7 do
        c := if !c land 1 = 1 then 0xedb88320 lxor (!c lsr 1) else !c lsr 1
      done;
      !c)

let crc32 s =
  let c = ref 0xffffffff in
  String.iter (fun ch -> c := crc_table.((!c lxor Char.code ch) land 0xff) lxor (!c lsr 8)) s;
  !c lxor 0xffffffff

let write_zip path (members : (string * string) list) =
  let b = Buffer.create 65536 in
  let u16 n = Buffer.add_uint16_le b (n land 0xffff) in
  let u32 n = Buffer.add_int32_le b (Int32.of_int (n land 0xffffffff)) in
  let dos_time = 0 and dos_date = (0 lsl 9) lor (1 lsl 5) lor 1 (* 1980-01-01 *) in
  let central =
    List.map
      (fun (name, data) ->
        let off = Buffer.length b in
        let crc = crc32 data and n = String.length data in
        if n > 0xfffffffe || off > 0xfffffffe then fail "Cairo PIE member %s is too large for this zip writer" name;
        u32 0x04034b50; u16 20; u16 0; u16 0; u16 dos_time; u16 dos_date; u32 crc; u32 n; u32 n;
        u16 (String.length name); u16 0;
        Buffer.add_string b name;
        Buffer.add_string b data;
        (name, crc, n, off))
      members
  in
  let cd_start = Buffer.length b in
  List.iter
    (fun (name, crc, n, off) ->
      u32 0x02014b50; u16 20; u16 20; u16 0; u16 0; u16 dos_time; u16 dos_date; u32 crc; u32 n; u32 n;
      u16 (String.length name); u16 0; u16 0; u16 0; u16 0; u32 0; u32 off;
      Buffer.add_string b name)
    central;
  let cd_size = Buffer.length b - cd_start in
  u32 0x06054b50; u16 0; u16 0; u16 (List.length members); u16 (List.length members); u32 cd_size; u32 cd_start;
  u16 0;
  let oc = open_out_bin path in
  Buffer.output_buffer oc b;
  close_out oc

(* ---- PIE contents ---- *)

let suffix k = bname k ^ "_builtin"

(* BuiltinName's derived Ord (enum declaration order) *)
let ord_rank = function
  | Output -> 0 | Range_check -> 1 | Pedersen -> 2 | Ecdsa -> 3 | Keccak -> 4 | Bitwise -> 5 | Ec_op -> 6
  | Poseidon -> 7 | Range_check96 -> 9 | Add_mod -> 10 | Mul_mod -> 11

let by_ord l = List.sort (fun (a, _) (b, _) -> compare (ord_rank a) (ord_rank b)) l

let canonical z = Felt.to_z (Felt.of_z z)

let memory_bytes (r : Runner.t) remap =
  let vm = r.vm in
  let b = Buffer.create (1 lsl 20) in
  let base63 = Z.shift_left Z.one 63 and base255 = Z.shift_left Z.one 255 in
  let addr seg off =
    let seg, off = remap seg off in
    Z.add base63 (Z.add (Z.mul (Z.of_int seg) (Z.of_int 0x800000000000)) (Z.of_int off))
  in
  let le z n =
    let s = Z.to_bits z in
    let s = if String.length s >= n then String.sub s 0 n else s ^ String.make (n - String.length s) '\000' in
    Buffer.add_string b s
  in
  for s = 0 to vm.nsegs - 1 do
    for o = 0 to used_size vm s - 1 do
      let v = read vm s o in
      if v <> 0 then begin
        le (addr s o) 8;
        if Felt.is_reloc v then begin
          let rs, ro = remap (Felt.rseg v) (Felt.roff v) in
          le (Z.add base255 (Z.add (Z.mul (Z.of_int rs) (Z.of_int 0x800000000000)) (Z.of_int ro))) 32
        end
        else le (Felt.to_z v) 32
      end
    done
  done;
  Buffer.contents b

let write (r : Runner.t) ~main ~secure ~merge_extra_segments path =
  if r.proof then fail "Cairo PIE output cannot be used in proof mode";
  let vm = r.vm in
  let seg_info i n = Obj [ ("index", int i); ("size", int n) ] in
  let builtins = vm.builtins in
  let stop b = if b.stop_ptr < 0 then fail "No stop pointer found for builtin %s" (bname b.kind) else b.stop_ptr in
  let n_used = List.length r.prog_builtins in
  let ret_fp = read vm 1 n_used and ret_pc = read vm 1 (n_used + 1) in
  let check_ret v what =
    if v = 0 || not (Felt.is_reloc v) then fail "Expected relocatable %s at 1:%d" what n_used;
    if used_size vm (Felt.rseg v) <> 0 then fail "Unexpected %s segment size" what;
    if Felt.roff v <> 0 then fail "%s offset is not zero" what
  in
  check_ret ret_fp "return fp";
  check_ret ret_pc "return pc";
  let known = 0 :: 1 :: Felt.rseg ret_fp :: Felt.rseg ret_pc :: List.map (fun b -> b.base) builtins in
  let extra = List.filter (fun s -> not (List.mem s known)) (List.init vm.nsegs Fun.id) in
  let extra_infos = List.map (fun s -> (s, used_size vm s)) extra in
  let extra_json, remap =
    match (merge_extra_segments, extra_infos) with
    | true, (first, _) :: _ ->
        let tbl = Hashtbl.create 8 in
        let acc = List.fold_left (fun a (s, n) -> Hashtbl.replace tbl s a; a + n) 0 extra_infos in
        ( [ seg_info first acc ],
          fun s o -> match Hashtbl.find_opt tbl s with Some a -> (first, a + o) | None -> (s, o) )
    | _ -> (List.map (fun (s, n) -> seg_info s n) extra_infos, fun s o -> (s, o))
  in
  let ordered = List.filter_map (fun k -> List.find_opt (fun b -> b.kind = k) builtins) all_builtins in
  let metadata =
    Obj
      [
        ( "program",
          Obj
            [
              ("data", Arr (Array.to_list (Array.map (fun z -> Num (Z.to_string (canonical z))) r.prog.data)));
              ("builtins", Arr (List.map (fun k -> Str (bname k)) r.prog_builtins));
              ("main", int main);
              ("prime", Num (Z.to_string Felt.p));
            ] );
        ("program_segment", seg_info 0 (Array.length r.prog.data));
        ("execution_segment", seg_info 1 vm.ap);
        ("ret_fp_segment", seg_info (Felt.rseg ret_fp) 0);
        ("ret_pc_segment", seg_info (Felt.rseg ret_pc) 0);
        ("builtin_segments", Obj (List.map (fun b -> (bname b.kind, seg_info b.base (stop b))) ordered));
        ("extra_segments", Arr extra_json);
      ]
  in
  let additional =
    Obj
      (List.map
         (fun (k, b) ->
           ( suffix k,
             match k with
             | Output -> Obj [ ("pages", Obj []); ("attributes", Obj []) ]
             | Pedersen -> Arr (List.map (fun o -> Arr [ int b.base; int o ]) (Runner.pedersen_verified ~secure r b))
             | Ecdsa ->
                 let sigs = List.sort compare (Hashtbl.fold (fun o rs acc -> (o, rs) :: acc) Builtins_ext.signatures []) in
                 let num z = Num (Z.to_string (Z.erem z Felt.p)) in
                 Arr (List.map (fun (o, (r_, s_)) -> Arr [ Arr [ int b.base; int o ]; Arr [ num r_; num s_ ] ]) sigs)
             | _ -> Null ))
         (by_ord (List.map (fun b -> (b.kind, b)) builtins)))
  in
  let resources =
    Obj
      [
        ("n_steps", int vm.steps);
        ("n_memory_holes", int (Runner.memory_holes r));
        ( "builtin_instance_counter",
          Obj (List.map (fun (k, b) -> (suffix k, int (Runner.used_instances r b))) (by_ord (List.map (fun b -> (b.kind, b)) builtins))) );
      ]
  in
  write_zip path
    [
      ("version.json", to_string (Obj [ ("cairo_pie", Str "1.1") ]));
      ("metadata.json", to_string metadata);
      ("memory.bin", memory_bytes r remap);
      ("additional_data.json", to_string additional);
      ("execution_resources.json", to_string resources);
    ]
