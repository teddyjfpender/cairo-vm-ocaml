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
    let size = if r.proof then segment_size r s else used_size vm s in
    t.(s + 1) <- t.(s) + size
  done;
  t

external c_write_trace : string -> seg -> int -> int array -> unit = "cvm_write_trace"

external c_write_memory : string -> seg array -> int array -> int array -> int -> bytes -> unit
  = "cvm_write_memory_byte" "cvm_write_memory"

let write_trace r path =
  let vm = r.vm in
  c_write_trace path vm.trace vm.tlen (relocation_table r)

let write_memory r path =
  let vm = r.vm in
  (* relocate_value rejects temporary segments (TemporarySegmentInRelocation) *)
  if vm.had_temp then check_no_temp_values vm;
  let sizes = Array.init vm.nsegs (used_size vm) in
  c_write_memory path vm.segs sizes (relocation_table r) vm.nsegs !Felt.pool

(* first and last trace entries as (pc_seg, pc, ap, fp) *)
let trace_bounds r =
  let vm = r.vm in
  if vm.tlen = 0 then None
  else begin
    let i = ref 0 and first = ref None and last = ref (0, 0, 0, 0) in
    while !i < vm.tlen do
      let next, s, pc, ap, fp = trace_entry vm.trace !i in
      if !first = None then first := Some (s, pc, ap, fp);
      last := (s, pc, ap, fp);
      i := next
    done;
    Option.map (fun f -> (f, !last)) !first
  end

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
