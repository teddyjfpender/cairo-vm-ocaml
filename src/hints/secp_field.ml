type t = bytes
type modulus = t

external c_op : bytes -> (int[@untagged]) -> bytes -> bytes -> bytes -> (int[@untagged])
  = "cvm_sf_op_byte" "cvm_sf_op" [@@noalloc]
external c_pack :
  bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> bytes -> bytes -> (int[@untagged]) ->
  (int[@untagged]) = "cvm_sf_pack_byte" "cvm_sf_pack" [@@noalloc]
external c_limb86 : bytes -> bytes -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "cvm_sf_limb86_byte" "cvm_sf_limb86" [@@noalloc]

let of_z z =
  assert (Z.sign z >= 0 && Z.numbits z <= 256);
  let b = Bytes.make 32 '\000' and s = Z.to_bits z in
  Bytes.blit_string s 0 b 0 (min 32 (String.length s));
  b

let to_z t = Z.of_bits (Bytes.to_string t)

(* Hints pass the same few prime constants over and over. *)
let last = ref (Z.zero, None)

let modulus p =
  if fst !last != p then
    last := (p, if Z.gt p Z.one && Z.numbits p <= 256 then Some (of_z p) else None);
  snd !last

let op k m a b =
  let r = Bytes.create 32 in
  if c_op m k a b r = 0 then None else Some r

let total k m a b = Option.get (op k m a b)
let add = total 0
let sub = total 1
let mul = total 2
let div = op 3

let pack_code m (d0 : Felt.t) (d1 : Felt.t) (d2 : Felt.t) r =
  Felt.reserve 1;
  c_pack !Felt.pool (d0 :> int) (d1 :> int) (d2 :> int) m r !Felt.pool_n

let pack m d0 d1 d2 =
  let r = Bytes.create 32 in
  ignore (pack_code m d0 d1 d2 r);
  r

let exact_quotient m d0 d1 d2 =
  let q = pack_code m d0 d1 d2 (Bytes.create 32) in
  if q = 0 then None
  else begin
    let q = Felt.unsafe_of_int q in
    Felt.commit q;
    Some q
  end

let limb86 t i =
  Felt.reserve 1;
  let c = Felt.unsafe_of_int (c_limb86 !Felt.pool t i !Felt.pool_n) in
  Felt.commit c;
  c
