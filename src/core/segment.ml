(* Memory segments and the trace live outside the OCaml heap: every cell is an
   immediate, so there is nothing for the GC to scan or barrier. *)
module BA = Bigarray.Array1
type seg = (int, Bigarray.int_elt, Bigarray.c_layout) BA.t
external seg_make : int -> seg = "cvm_zalloc"
let empty_seg : seg = seg_make 0
let[@inline] slen (a : seg) = BA.dim a
let[@inline] sget (a : seg) i = BA.unsafe_get a i
let[@inline] sset (a : seg) i v = BA.unsafe_set a i v
let seg_grow (a : seg) n = let na = seg_make n in BA.blit a (BA.sub na 0 (BA.dim a)); na
