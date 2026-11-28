open Errors
open Segment
open Builtin
open Vm
open Runner
open Resources

let check_no_temp_values vm =
  for s = 0 to vm.nsegs - 1 do
    let a = vm.segs.(s) in
    for i = 0 to min (used_size vm s) (slen a) - 1 do
      let v = sget a i in
      if Felt.is_reloc v && Felt.rseg v < 0 then
        fail "Invalid memory value at %d:%d: temporary address %d:%d" s i (Felt.rseg v) (Felt.roff v)
    done
  done

let relocation_table r =
  let vm = r.vm in
  let t = Array.make (vm.nsegs + 1) 1 in
  for s = 0 to vm.nsegs - 1 do
    (* proof runs and runs from a PIE finalize their segment sizes *)
    let size = if r.proof || Hashtbl.length r.seg_sizes > 0 then segment_size r s else used_size vm s in
    t.(s + 1) <- t.(s) + size
  done;
  t

external c_write_trace : string -> seg -> int -> int array -> unit = "cvm_write_trace"

(* A trace or memory file being produced by a background C thread. The job
   reads only bigarray data (trace, segments, felt pool), which neither moves
   nor changes after the run; [finish] joins it, closes the file and raises
   its first error. *)
type pending = nativeint

external c_start_trace : string -> seg -> int -> int array -> pending = "cvm_start_trace"

external c_start_memory : string -> seg array -> int array -> int array -> int -> Felt.pool -> pending
  = "cvm_start_memory_byte" "cvm_start_memory"

external finish : pending -> unit = "cvm_finish_artifact"

let start_trace r path =
  let vm = r.vm in
  c_start_trace path vm.trace vm.tlen (relocation_table r)

let start_memory r path =
  let vm = r.vm in
  (* relocate_value rejects temporary segments (TemporarySegmentInRelocation) *)
  if vm.had_temp then check_no_temp_values vm;
  let sizes = Array.init vm.nsegs (used_size vm) in
  c_start_memory path vm.segs sizes (relocation_table r) vm.nsegs Felt.pool

let write_trace r path = finish (start_trace r path)
let write_memory r path = finish (start_memory r path)

let finish_all jobs =
  let first = List.fold_left (fun err j -> match finish j with () -> err | exception e -> if err = None then Some e else err) None jobs in
  Option.iter raise first

let with_artifacts r ~trace ~memory k =
  match trace, memory with
  | Some t, Some m when t = m ->
      (* one file named twice: keep the sequential overwrite order *)
      write_trace r t; write_memory r m; k ()
  | _ ->
      let jt = Option.map (start_trace r) trace in
      let jm = try Option.map (start_memory r) memory with e -> finish_all (Option.to_list jt); raise e in
      let jobs = Option.to_list jt @ Option.to_list jm in
      (match k () with
       | v -> finish_all jobs; v
       | exception e -> finish_all jobs; raise e)

(* first and last trace entries as (pc_seg, pc, ap, fp) *)
let trace_bounds r =
  let vm = r.vm in
  if vm.tlen = 0 then None
  else
    let entry i =
      let _, seg, pc, ap, fp = trace_entry vm.trace i in
      seg, pc, ap, fp
    in
    Some (entry 0, entry vm.last_trace)

let output_segment r =
  List.find_opt (fun b -> b.kind = Output) r.vm.builtins

let output_line vm seg i =
  let v = read vm seg i in
  if v = Felt.empty then "<missing>"
  else if Felt.is_small v then string_of_int (Felt.small_val v)
  else if Felt.is_reloc v then Printf.sprintf "%d:%d" (Felt.rseg v) (Felt.roff v)
  else Z.to_string (Felt.to_signed_z v)

let iter_output_lines r emit =
  match output_segment r with
  | None -> ()
  | Some b ->
      for i = 0 to used_size r.vm b.base - 1 do
        emit (output_line r.vm b.base i)
      done

external output_chunk : Felt.pool -> seg -> int -> int ref -> bytes -> int = "cvm_output_chunk" [@@noalloc]

let write_output channel r =
  match output_segment r with
  | None -> ()
  | Some b ->
      let total = used_size r.vm b.base in
      if total < 64 then iter_output_lines r (fun line -> output_string channel line; output_char channel '\n')
      else begin
        let capacity = if total >= 820 then 65536 else 80 * total in
        let buf = Bytes.create capacity and cursor = ref 0 in
        while !cursor < total do
          let size = output_chunk Felt.pool r.vm.segs.(b.base) total cursor buf in
          if size <= 0 then invalid_arg "output buffer";
          output channel buf 0 size
        done
      end

let output_lines r =
  match output_segment r with
  | None -> []
  | Some b -> List.init (used_size r.vm b.base) (output_line r.vm b.base)

(* Offsets cairo-vm's pedersen runner records as verified: output cells whose
   inputs were present when it deduced them (during the run, in
   verify_auto_deductions over the segment, and for missing outputs in the
   secure-run check, which covers the last partial instance). *)
let pedersen_verified ~secure r b =
  let vm = r.vm in
  let len = used_size vm b.base in
  let limit = if secure then div_ceil len 3 * 3 else len in
  let rec go o acc =
    if o >= limit then List.rev acc
    else
      let a = read vm b.base (o - 1) and c = read vm b.base (o - 2) in
      go (o + 3) (if a <> Felt.empty && c <> Felt.empty && Felt.is_felt a && Felt.is_felt c then o :: acc else acc)
  in
  go 2 []
