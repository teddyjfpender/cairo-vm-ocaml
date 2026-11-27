open Errors
open Builtin
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

(* Members emit bounded chunks. Patch the CRC and size in the local header
   once the member has been written, retaining the stored ZIP format. *)
external crc_update : int -> bytes -> int -> int = "cvm_pie_crc_update"

let text_member s emit = emit (Bytes.unsafe_of_string s) (String.length s)

let write_zip path members =
  Out_channel.with_open_bin path (fun oc ->
    let u16 n = output_byte oc n; output_byte oc (n lsr 8) in
    let u32 n = u16 n; u16 (n lsr 16) in
    let central = List.map (fun (name, write) ->
      let off = pos_out oc in
      if off > 0xfffffffe then fail "Cairo PIE zip exceeds the size limit";
      u32 0x04034b50; u16 20; u16 0; u16 0; u16 0; u16 33;
      u32 0; u32 0; u32 0; u16 (String.length name); u16 0; output_string oc name;
      let start = pos_out oc and crc = ref 0 in
      write (fun bytes len ->
        crc := crc_update !crc bytes len;
        output oc bytes 0 len);
      let stop = pos_out oc in
      let n = stop - start in
      if stop > 0xfffffffe then fail "Cairo PIE zip exceeds the size limit";
      seek_out oc (off + 14); u32 !crc; u32 n; u32 n; seek_out oc stop;
      name, !crc, n, off) members in
    let start = pos_out oc in
    List.iter (fun (name, crc, n, off) ->
      u32 0x02014b50; u16 20; u16 20; u16 0; u16 0; u16 0; u16 33;
      u32 crc; u32 n; u32 n; u16 (String.length name); u16 0; u16 0;
      u16 0; u16 0; u32 0; u32 off; output_string oc name) central;
    let size = pos_out oc - start in
    u32 0x06054b50; u16 0; u16 0; u16 (List.length members);
    u16 (List.length members); u32 size; u32 start; u16 0)

(* ---- PIE contents ---- *)

let suffix k = bname k ^ "_builtin"

(* BuiltinName's derived Ord (enum declaration order) *)
let ord_rank = function
  | Output -> 0 | Range_check -> 1 | Pedersen -> 2 | Ecdsa -> 3 | Keccak -> 4 | Bitwise -> 5 | Ec_op -> 6
  | Poseidon -> 7 | Range_check96 -> 9 | Add_mod -> 10 | Mul_mod -> 11

let by_ord l = List.sort (fun (a, _) (b, _) -> compare (ord_rank a) (ord_rank b)) l

let canonical z = Felt.to_z (Felt.of_z z)

let memory_member (r : Runner.t) remap emit =
  let vm = r.vm in
  let chunk = Bytes.create (40 * 8192) and pos = ref 0 in
  let address seg off =
    let seg, off = remap seg off in
    Int64.logor (Int64.shift_left (Int64.of_int seg) 47) (Int64.of_int off)
  in
  for seg = 0 to vm.nsegs - 1 do
    for off = 0 to used_size vm seg - 1 do
      let v = read vm seg off in
      if v <> Felt.empty then begin
        Bytes.set_int64_le chunk !pos (Int64.logor Int64.min_int (address seg off));
        let dst = !pos + 8 in
        if Felt.is_reloc v then begin
          Bytes.set_int64_le chunk dst (address (Felt.rseg v) (Felt.roff v));
          Bytes.set_int64_le chunk (dst + 8) 0L;
          Bytes.set_int64_le chunk (dst + 16) 0L;
          Bytes.set_int64_le chunk (dst + 24) Int64.min_int
        end else Felt.c_put_code Felt.pool (v :> int) chunk dst;
        pos := !pos + 40;
        if !pos = Bytes.length chunk then (emit chunk !pos; pos := 0)
      end
    done
  done;
  if !pos > 0 then emit chunk !pos

let write ?output_pages ?output_attributes ?(pedersen_extra = []) (r : Runner.t) ~main ~secure
    ~merge_extra_segments path =
  let output_pages = Option.value output_pages ~default:r.output_pages in
  let output_attributes = Option.value output_attributes ~default:r.output_attributes in
  if r.proof then fail "Cairo PIE output cannot be used in proof mode";
  let vm = r.vm in
  let seg_info i n = Obj [ ("index", int i); ("size", int n) ] in
  let builtins = vm.builtins in
  let stop b = if b.stop_ptr < 0 then fail "No stop pointer found for builtin %s" (bname b.kind) else b.stop_ptr in
  let n_used = List.length r.prog_builtins in
  let ret_fp = read vm 1 n_used and ret_pc = read vm 1 (n_used + 1) in
  let check_ret v what =
    if v = Felt.empty || not (Felt.is_reloc v) then fail "Expected relocatable %s at 1:%d" what n_used;
    if used_size vm (Felt.rseg v) <> 0 then fail "Unexpected %s segment size" what;
    if Felt.roff v <> 0 then fail "%s offset is not zero" what
  in
  check_ret ret_fp "return fp";
  check_ret ret_pc "return pc";
  let known = 0 :: 1 :: Felt.rseg ret_fp :: Felt.rseg ret_pc :: List.map (fun b -> b.base) builtins in
  let extra = List.filter (fun s -> not (List.mem s known)) (List.init vm.nsegs Fun.id) in
  (* finalized sizes win (a run from a PIE finalizes every segment) *)
  let extra_infos = List.map (fun s -> (s, Resources.segment_size r s)) extra in
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
             | Output ->
                 Obj
                   [
                     ("pages", Obj (List.map (fun (id, (start, size)) -> (string_of_int id, Arr [ int start; int size ])) output_pages));
                     ("attributes", Obj (List.map (fun (k, l) -> (k, Arr (List.map int l))) output_attributes));
                   ]
             | Pedersen ->
                 let verified = List.sort_uniq compare (pedersen_extra @ Artifacts.pedersen_verified ~secure r b) in
                 Arr (List.map (fun o -> Arr [ int b.base; int o ]) verified)
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
        ("n_memory_holes", int (Resources.memory_holes r));
        ( "builtin_instance_counter",
          Obj (List.map (fun (k, b) -> (suffix k, int (Resources.used_instances r b))) (by_ord (List.map (fun b -> (b.kind, b)) builtins))) );
      ]
  in
  write_zip path
    [
      ("version.json", text_member (to_string (Obj [ ("cairo_pie", Str "1.1") ])));
      ("metadata.json", text_member (to_string metadata));
      ("memory.bin", memory_member r remap);
      ("additional_data.json", text_member (to_string additional));
      ("execution_resources.json", text_member (to_string resources));
    ]
