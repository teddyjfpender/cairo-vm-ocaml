open Cairovm

let p = Felt.p
let field x = Z.erem x p
let point x y = Z.of_string x, Z.of_string y
let a = point "0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804"
              "0x3ca0cfe4b3bc6ddf346d49d06ea0ed34e621062c0e056c1d0405d266e10268a"
let b = point "0x4ba4cc166be8dec764910f75b45f74b40c690c74709e90f3aa372f0bd2d6997"
              "0x40301cf5c1751f4b971e46c4ede85fcac5c59a5ce5ae7c48151f27b24b219c"

(* Independent affine group law. *)
let plus (x, y) (u, v) =
  let num, den =
    if Z.equal x u then Z.(one + of_int 3 * x * x), Z.(of_int 2 * y)
    else Z.(v - y), Z.(u - x)
  in
  let slope = field Z.(num * invert den p) in
  let rx = field Z.(slope * slope - x - u) in
  rx, field Z.(slope * (x - rx) - y)

let rec reference acc q m =
  if Z.equal m Z.zero then Ok acc
  else if Z.equal (fst acc) (fst q) then Error 1
  else reference (if Z.testbit m 0 then plus acc q else acc)
                 (plus q q) (Z.shift_right m 1)

let execute (px, py) (qx, qy) m =
  List.iteri (fun i z ->
      let c = Felt.of_z z in Felt.c_load_slot !Felt.pool c i)
    [px; py; qx; qy; m];
  let status = Felt.c_ec_op !Felt.pool 0 5 in
  let read i =
    Felt.reserve 1;
    let c = Felt.c_code_of_slot !Felt.pool i !Felt.pool_n in
    Felt.commit c;
    Felt.to_z c
  in
  if status <> 0 then Error status else Ok (read 5, read 6)

let check a b m = assert (execute a b m = reference a b m)

let () =
  List.iter (check a b) Z.[zero; one; of_int 2; shift_left one 64; pred p];
  List.iter (check a a) Z.[zero; one; of_int 2];
  check (plus b b) b (Z.of_int 2);
  check (fst b, Z.sub p (snd b)) b Z.one;
  let m = ref Z.one in
  for i = 0 to 127 do
    m := field Z.(!m * of_int 251 + of_int 97);
    let p, q = if i mod 7 = 0 then b, a else a, b in
    check p q !m
  done;
  let invalid = Z.zero, Z.zero in
  assert (execute invalid b Z.zero = Error 2);
  assert (execute a invalid Z.zero = Error 2);
  check a b (Z.of_int 3)
