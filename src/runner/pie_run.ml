open Errors
open Builtin
open Vm
open Pie_file

type result = {
  runner : Runner.t;
  output_pages : (int * (int * int)) list;
  output_attributes : (string * int list) list;
  pedersen_extra : int list;
}

let main_pc (pie : Pie_file.t) = pie.main

module U = Yojson.Safe.Util

(* ---- CairoPie::run_validity_checks ---- *)

let pie_error m = fail "%s" m

let segment_infos pie =
  [ pie.program_segment; pie.execution_segment; pie.ret_fp_segment; pie.ret_pc_segment ]
  @ List.map snd pie.builtin_segments @ pie.extra_segments

(* serialized addresses: 16 segment bits above 47 offset bits *)
let n_offset_bits = 47
let offset_mask = (1 lsl n_offset_bits) - 1
let addr_of_word w = ((w lsr n_offset_bits) land 0xffff, w land offset_mask)

external address_bounds : bytes -> int array -> int array -> int -> bool
  = "cvm_pie_address_bounds" [@@noalloc]

let metadata_sizes pie =
  let nb = List.length pie.builtins in
  if pie.main > Array.length pie.data then pie_error "Invalid main() address.";
  if Array.length pie.data <> pie.program_segment.size then
    pie_error "Program length does not match the program segment size.";
  if List.length pie.builtin_segments <> nb || not (List.for_all (fun b -> List.mem_assoc b pie.builtin_segments) pie.builtins)
  then pie_error "Builtin list mismatch in builtin_segments.";
  if pie.ret_fp_segment.size <> 0 then pie_error "Invalid segment size for ret_fp. Must be 0.";
  if pie.ret_pc_segment.size <> 0 then pie_error "Invalid segment size for ret_pc. Must be 0.";
  if pie.program_segment.index <> 0 then pie_error "Invalid segment index for program_segment.";
  if pie.execution_segment.index <> 1 then pie_error "Invalid segment index for execution_segment.";
  List.iteri
    (fun i b ->
      if (List.assoc b pie.builtin_segments).index <> 2 + i then pie_error (Printf.sprintf "Invalid segment index for %s." b))
    pie.builtins;
  if pie.ret_fp_segment.index <> nb + 2 then pie_error "Invalid segment index for ret_fp_segment.";
  if pie.ret_pc_segment.index <> nb + 3 then pie_error "Invalid segment index for ret_pc_segment.";
  List.iteri (fun i s -> if s.index <> 4 + nb + i then pie_error "Invalid segment indices for extra_segments.") pie.extra_segments;
  (* every address lies inside its declared segment; the last declaration of an index wins *)
  let infos = segment_infos pie in
  let sizes = Array.make (List.length infos) 0 in
  List.iter (fun s ->
      if s.index >= Array.length sizes then pie_error "Invalid segment index";
      sizes.(s.index) <- s.size) infos;
  if List.length pie.builtin_instance_counter <> nb
     || not (List.for_all (fun b -> List.mem_assoc b pie.builtin_instance_counter) pie.builtins)
  then pie_error "Builtin list mismatch in builtin_segments.";
  sizes

(* ---- memory ---- *)

external pie_felt : Bytes.t -> (int[@untagged]) -> Felt.pool -> (int[@untagged]) -> (int[@untagged])
  = "cvm_pie_felt_byte" "cvm_pie_felt"
[@@noalloc]

let decode_value m pos =
  if Char.code (Bytes.get m (pos + 31)) land 0x80 <> 0 then begin
    let seg, off = addr_of_word (Int64.to_int (Bytes.get_int64_le m pos)) in
    if off > Vm.max_off then fail "Cairo PIE relocatable offset out of range: %d:%d" seg off;
    Felt.reloc seg off
  end
  else begin
    Felt.reserve 1;
    let c = Felt.unsafe_of_int (pie_felt m pos Felt.pool !Felt.pool_n) in
    Felt.commit c;
    c
  end

(* MemorySegmentManager::load_pie_memory: insert every cell in file order
   (write-once, with builtin validation). Returns whether the addresses are
   strictly increasing, the order cairo-vm serializes memory in. *)
external load_run : bytes -> int -> Segment.seg -> Felt.pool -> int array -> unit
  = "cvm_pie_load_run" [@@noalloc]

let load_memory vm pie sizes source =
  let occupied = Array.make (Array.length sizes) 0 in
  let sorted = ref true and prev_seg = ref (-1) and prev_off = ref (-1) in
  let count = ref 0 in
  let load m =
    if not (address_bounds m sizes occupied Vm.max_off) then pie_error "Invalid address";
    let n = Bytes.length m / cell_bytes in
    count := !count + n;
    let state = [|0; !Felt.pool_n; 0|] in
    while state.(0) < n do
      let i = state.(0) in
      let pos = i * cell_bytes in
      let seg, off = addr_of_word (Int64.to_int (Bytes.get_int64_le m pos)) in
      if seg < !prev_seg || (seg = !prev_seg && off <= !prev_off) then sorted := false;
      prev_seg := seg;
      (* Preallocate only as far as the validated addresses in this chunk.
         Empty tails in the segment metadata can be arbitrarily large. *)
      if not (seg_ok vm seg) then pie_error "Invalid PIE memory segment";
      if occupied.(seg) > Segment.slen vm.segs.(seg) then grow_seg vm seg (occupied.(seg)-1);
      if vm.seg_flag.(seg) = k_plain && off >= vm.hi.(seg) then begin
        state.(1) <- !Felt.pool_n;
        state.(2) <- vm.hi.(seg);
        load_run m seg vm.segs.(seg) Felt.pool state;
        Felt.pool_n := state.(1);
        vm.hi.(seg) <- state.(2)
      end;
      if state.(0) = i then begin
        write vm seg off (decode_value m (pos + 8));
        state.(0) <- i + 1;
        prev_off := off
      end else prev_off := state.(2) - 1
    done in
  (match source with None -> load pie.memory | Some src -> iter_memory src load);
  !sorted, !count

let count_cells vm =
  let n = ref 0 in
  for s = 0 to vm.nsegs - 1 do
    for o = 0 to used_size vm s - 1 do
      if Vm.read vm s o <> Felt.empty then incr n
    done
  done;
  !n

(* ---- additional data (BuiltinRunner::extend_additional_data) ---- *)

let output_data j =
  let pages =
    match U.member "pages" j with
    | `Assoc l ->
        List.map
          (fun (k, v) ->
            match U.to_list v with
            | [ a; b ] -> (int_of_string k, (int_of_json a, int_of_json b))
            | _ -> fail "Invalid Cairo PIE: bad output page")
          l
    | `Null -> []
    | _ -> fail "Invalid Cairo PIE: bad output pages"
  in
  let attributes =
    match U.member "attributes" j with
    | `Assoc l -> List.map (fun (k, v) -> (k, List.map int_of_json (U.to_list v))) l
    | `Null -> []
    | _ -> fail "Invalid Cairo PIE: bad output attributes"
  in
  (* BTreeMap order, later keys replacing earlier ones *)
  let dedup cmp l =
    let tbl = Hashtbl.create 8 in
    List.iter (fun (k, v) -> Hashtbl.replace tbl k v) l;
    List.sort (fun (a, _) (b, _) -> cmp a b) (Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [])
  in
  (dedup compare pages, dedup String.compare attributes)

let signature_data base j =
  List.map
    (fun e ->
      match U.to_list e with
      | [ addr; rs ] -> (
          match (U.to_list addr, U.to_list rs) with
          | [ s; o ], [ r; s' ] ->
              if int_of_json s <> base then fail "Invalid additional data for builtin ecdsa";
              (int_of_json o, (z_of_json r, z_of_json s'))
          | _ -> fail "Invalid additional data for builtin ecdsa")
      | _ -> fail "Invalid additional data for builtin ecdsa")
    (match j with `List l -> l | `Null -> [] | _ -> fail "Invalid additional data for builtin ecdsa")

let pedersen_data base j =
  List.map
    (fun e ->
      match U.to_list e with
      | [ s; o ] ->
          if int_of_json s <> base then fail "Invalid additional data for builtin pedersen";
          int_of_json o
      | _ -> fail "Invalid additional data for builtin pedersen")
    (match j with `List l -> l | `Null -> [] | _ -> fail "Invalid additional data for builtin pedersen")

(* ---- CairoPie::check_pie_compatibility ---- *)

let check_compatibility (r : Runner.t) pie ~sorted ~cell_count ~pages ~attributes =
  let vm = r.vm in
  let builtin_of name = List.find_opt (fun b -> bname b.kind = name) vm.builtins in
  (* metadata: segments the runner would write into its own PIE *)
  let n_used = List.length r.prog_builtins in
  let ret_seg k = let v = Vm.read vm 1 (n_used + k) in if Felt.is_reloc v then Felt.rseg v else -1 in
  let ret_fp = ret_seg 0 and ret_pc = ret_seg 1 in
  let known = 0 :: 1 :: ret_fp :: ret_pc :: List.map (fun b -> b.base) vm.builtins in
  let extra =
    List.filter_map
      (fun s -> if List.mem s known then None else Some { index = s; size = Resources.segment_size r s })
      (List.init vm.nsegs Fun.id)
  in
  let builtins_ok =
    List.length vm.builtins = List.length pie.builtin_segments
    && List.for_all
         (fun (name, info) ->
           match builtin_of name with Some b -> b.base = info.index && b.stop_ptr = info.size | None -> false)
         pie.builtin_segments
  in
  if vm.ap <> pie.execution_segment.size || ret_fp <> pie.ret_fp_segment.index || ret_pc <> pie.ret_pc_segment.index
     || (not builtins_ok) || extra <> pie.extra_segments
  then
    pie_error "Cairo PIE diff: metadata mismatch";
  (* write-once memory already holds every loaded cell with its PIE value *)
  if (not sorted) || count_cells vm <> cell_count then pie_error "Cairo PIE diff: memory mismatch";
  let counters_ok =
    List.length vm.builtins = List.length pie.builtin_instance_counter
    && List.for_all
         (fun (name, n) -> match builtin_of name with Some b -> Resources.used_instances r b = n | None -> false)
         pie.builtin_instance_counter
  in
  if vm.steps <> pie.n_steps || not counters_ok then pie_error "Cairo PIE diff: execution_resources mismatch";
  if List.length pie.additional <> List.length vm.builtins then pie_error "Cairo PIE diff: additional_data mismatch";
  List.iter
    (fun b ->
      let name = bname b.kind in
      let mismatch () = pie_error (Printf.sprintf "Cairo PIE diff: additional_data[%s] mismatch" name) in
      match (b.kind, List.assoc_opt name pie.additional) with
      | Pedersen, _ -> ()
      | _, None -> mismatch ()
      | Output, Some j -> if output_data j <> (pages, attributes) then mismatch ()
      | Ecdsa, Some j ->
          let theirs = List.sort compare (signature_data b.base j) in
          let ours = List.sort compare (Builtins_ext.segment_signatures vm b.base) in
          let canon = List.map (fun (o, (r, s)) -> (o, (Z.erem r Felt.p, Z.erem s Felt.p))) in
          if canon theirs <> canon ours then mismatch ()
      | _, Some `Null -> ()
      | _, Some _ -> mismatch ())
    vm.builtins

(* ---- cairo_run_pie ---- *)

let stripped_program pie =
    {
      Program.data = pie.data; builtins = pie.builtins; main = Some pie.main; start = None; end_ = None; hints = [];
      references = [||]; identifiers = Hashtbl.create 1;
    }

let run ?source ~layout ~trace ~secure ~allow_missing_builtins ~fill_holes (pie : Pie_file.t) =
  let sizes = metadata_sizes pie in
  let prog = stripped_program pie in
  let cfg = { Runner.layout; trace; secure_run = secure; allow_missing_builtins; entrypoint = "main" } in
  let r = Runner.initialize cfg prog in
  let vm = r.vm in
  (* VirtualMachine::finalize_segments_by_cairo_pie *)
  List.iter (fun s -> Hashtbl.replace r.seg_sizes s.index s.size) (segment_infos pie);
  let pages = ref [] and attributes = ref [] and pedersen_extra = ref [] in
  List.iter
    (fun (name, j) ->
      match List.find_opt (fun b -> bname b.kind = name) vm.builtins with
      | None -> ()
      | Some b -> (
          match b.kind with
          | Output ->
              let p, a = output_data j in
              pages := p;
              attributes := a
          | Ecdsa -> List.iter (fun (o, rs) -> Builtins_ext.add_signature vm (Felt.reloc b.base o) rs) (signature_data b.base j)
          | Pedersen -> if not secure then pedersen_extra := pedersen_data b.base j
          | _ -> ()))
    pie.additional;
  (* the mod builtins' zero segment stands for the first extra segment *)
  let n_extra = List.length pie.extra_segments - if r.zero_seg >= 0 then 1 else 0 in
  for _ = 1 to n_extra do
    ignore (add_segment vm)
  done;
  let sorted,cell_count = load_memory vm pie sizes source in
  Resources.with_preverified_pedersen vm (fun () ->
      Cpu.run ~stop:(r.end_seg, 0) ~steps:pie.n_steps vm r.hints);
  if not (vm.pc_seg = r.end_seg && vm.pc = 0) then
    fail "Could not reach the end of the program. RunResources has no remaining steps.";
  Finalize.end_run ~fill_holes r ~secure ~allow_missing:allow_missing_builtins;
  if secure then check_compatibility r pie ~sorted ~cell_count ~pages:!pages ~attributes:!attributes;
  { runner = r; output_pages = !pages; output_attributes = !attributes; pedersen_extra = !pedersen_extra }

let write_output ?compression_level ~secure ~merge_extra_segments result path =
  let main = Option.get result.runner.prog.main in
  Pie.write ?compression_level ~output_pages:result.output_pages ~output_attributes:result.output_attributes
    ~pedersen_extra:result.pedersen_extra result.runner ~main ~secure ~merge_extra_segments path

let replay_file ?(layout = "all_cairo") ?trace ?memory ?output path =
  Felt.with_temporary_slots (fun () ->
    let pie,source = read_deferred path in
    let result = run ~source ~layout ~trace:(Option.is_some trace || Option.is_some output)
        ~secure:true ~allow_missing_builtins:false ~fill_holes:false pie in
    Artifacts.with_artifacts result.runner ~trace ~memory (fun () ->
        Option.iter (write_output ~secure:true ~merge_extra_segments:false result) output))

external load_nested_run :
  bytes -> int -> Segment.seg -> Felt.pool -> int array -> Felt.t array -> unit
  = "cvm_pie_load_nested_byte" "cvm_pie_load_nested" [@@noalloc]

(* The bootloader nests the task's segments in the caller's VM. In particular,
   a builtin can start at a nonzero offset or be represented by an integer. *)
let load_subtask ?source vm pie ~code ~stack ~ret_fp ~ret_pc =
  let sizes = metadata_sizes pie in
  let occupied = Array.make (Array.length sizes) 0 in
  let chunks ?parallel f = match source with None -> f pie.memory | Some src -> iter_memory ?parallel src f in
  let bases = Array.make (Array.length occupied) Felt.empty in
  let map index target =
    if index < 0 || index >= Array.length bases || bases.(index) <> Felt.empty then
      fail "Invalid or duplicate task segment mapping";
    bases.(index) <- target in
  map pie.program_segment.index code;
  map pie.execution_segment.index stack;
  map pie.ret_fp_segment.index ret_fp;
  map pie.ret_pc_segment.index ret_pc;
  let nb = List.length pie.builtins in
  let mapped = ref 0 in
  let exception Mapped in
  if nb <> 0 then begin
    try chunks ~parallel:false (fun bytes ->
        for i = 0 to Bytes.length bytes / cell_bytes - 1 do
          let pos = i*cell_bytes in
          let seg,off = addr_of_word (Int64.to_int (Bytes.get_int64_le bytes pos)) in
          if seg = pie.execution_segment.index && off < nb then begin
            let ptr = decode_value bytes (pos+8) in
            if not (Felt.is_reloc ptr) then fail "Expected task builtin pointer";
            map (Felt.rseg ptr) (Hintrt.mem_at vm stack off);
            incr mapped;
            if !mapped = nb then raise Mapped
          end
        done)
    with Mapped -> ()
  end;
  if !mapped <> nb then fail "Missing builtin pointers on task stack";
  List.iter (fun info -> map info.index (Felt.reloc (Vm.add_segment vm) 0)) pie.extra_segments;
  let relocate seg off =
    if seg < 0 || seg >= Array.length bases || bases.(seg) = Felt.empty then fail "Unmapped task segment";
    let base = bases.(seg) in
    if Felt.is_reloc base then Vm.reloc_add_felt base (Felt.of_int off) else base in
  (match List.assoc_opt "ecdsa" pie.additional, List.assoc_opt "ecdsa" pie.builtin_segments with
   | Some j, Some segment ->
       List.iter (fun (off, rs) ->
           let ptr = relocate segment.index off in
           if not (Felt.is_reloc ptr) then fail "Task signature address is not relocatable";
           (match vm.seg_builtin.(Felt.rseg ptr) with
            | Some b when b.kind = Ecdsa -> ()
            | _ -> fail "Task signature address is outside the ECDSA builtin");
           Builtins_ext.add_signature vm ptr rs) (signature_data segment.index j)
   | _ -> ());
  chunks (fun bytes ->
    if not (address_bounds bytes sizes occupied Vm.max_off) then pie_error "Invalid address";
    let state = [|0; !Felt.pool_n; 0|] in
    while state.(0) < Bytes.length bytes / cell_bytes do
      let i = state.(0) in
      let pos = i * cell_bytes in
      let seg, off = addr_of_word (Int64.to_int (Bytes.get_int64_le bytes pos)) in
      let dest = relocate seg off in
      if not (Felt.is_reloc dest) then fail "Task memory address is not relocatable";
      let target = Felt.rseg dest and offset = Felt.roff dest in
      if Vm.seg_ok vm target && vm.seg_flag.(target) = k_plain && offset >= vm.hi.(target) then begin
        (* Grow only for addresses actually present in the validated archive. *)
        let base = Felt.roff bases.(seg) in
        let last = base + occupied.(seg) - 1 in
        if last <= Vm.max_off && last >= Segment.slen vm.segs.(target) then Vm.grow_seg vm target last;
        state.(1) <- !Felt.pool_n;
        state.(2) <- vm.hi.(target);
        load_nested_run bytes seg vm.segs.(target) Felt.pool state bases;
        Felt.pool_n := state.(1);
        vm.hi.(target) <- state.(2)
      end;
      if state.(0) = i then begin
        let value = decode_value bytes (pos + 8) in
        let value = if Felt.is_reloc value then relocate (Felt.rseg value) (Felt.roff value) else value in
        Vm.write_checked vm target offset value;
        state.(0) <- i + 1
      end
    done)
