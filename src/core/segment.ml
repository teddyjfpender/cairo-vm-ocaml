module BA = Bigarray.Array1
type seg = (int, Bigarray.int_elt, Bigarray.c_layout) BA.t
external seg_make : int -> seg = "cvm_zalloc"
let empty_seg : seg = seg_make 0
let[@inline] slen (a : seg) = BA.dim a
let[@inline] sget (a : seg) i = Felt.unsafe_of_int (BA.unsafe_get a i)
let[@inline] sset (a : seg) i (v : Felt.t) = BA.unsafe_set a i (v :> int)
let[@inline] raw_get (a : seg) i = BA.unsafe_get a i
let[@inline] raw_set (a : seg) i (v : int) = BA.unsafe_set a i v
let seg_grow (a : seg) n = let na = seg_make n in BA.blit a (BA.sub na 0 (BA.dim a)); na

let snapshot ?(off=0) a n =
  let copy = seg_make n in
  BA.blit (BA.sub a off n) copy;
  copy

external contains_mark : bytes -> int -> int -> bool = "cvm_contains_mark" [@@noalloc]
let range_marked map off length =
  if off < 0 || off >= Bytes.length map || length <= 0 then false
  else if length = 1 then Bytes.unsafe_get map off <> '\000'
  else contains_mark map off (min length (Bytes.length map - off))

(* Repeat the last packed entry, or full register triple, in a trace. *)
let repeat_trace_tail trace ~first ~used ~copies =
  let width = used - first in
  if first < 0 || used > slen trace || (width <> 1 && width <> 3) || copies < 0 ||
     copies > (max_int - used - 2) / width then invalid_arg "Invalid padding trace length";
  let finish = used + copies * width in
  let trace = if finish > slen trace then seg_grow trace (finish + 2) else trace in
  if width = 1 then BA.fill (BA.sub trace used copies) (raw_get trace first)
  else begin
    let rec fill filled =
      let n = min filled (finish - first - filled) in
      if n > 0 then begin
        BA.blit (BA.sub trace first n) (BA.sub trace (first + filled) n);
        fill (filled + n)
      end in
    fill width
  end;
  trace, finish
