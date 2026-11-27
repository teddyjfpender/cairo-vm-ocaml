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
