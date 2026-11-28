(* Expand the pinned compressed BLS12-381 monomial basis at build time.
   Store canonical affine coordinates as fixed-width little-endian limbs. *)
let prime = Z.of_string "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
let points = 4096 and width = 48
let () =
  let data = In_channel.with_open_bin Sys.argv.(1) In_channel.input_all in
  if String.length data <> points * width then failwith "Invalid BLS12-381 monomial setup length";
  let coordinates = Bytes.make (points * 2 * width) '\000' in
  let half = Z.shift_right prime 1 and exponent = Z.shift_right (Z.succ prime) 2 in
  let write offset value =
    let bytes = Z.to_bits value in
    Bytes.blit_string bytes 0 coordinates offset (String.length bytes) in
  for i = 0 to points-1 do
    let encoded = Z.of_bits (String.init width (fun k -> data.[(i+1)*width-1-k])) in
    let x = Z.extract encoded 0 381 in
    if not (Z.testbit encoded 383) || Z.testbit encoded 382 || Z.geq x prime then
      failwith "Invalid compressed BLS12-381 setup coordinate";
    let rhs = Z.erem Z.(x*x*x + of_int 4) prime in
    let y = Z.powm rhs exponent prime in
    if not (Z.equal (Z.erem Z.(y*y) prime) rhs) then failwith "Invalid BLS12-381 setup point";
    let y = if Z.gt y half = Z.testbit encoded 381 then y else Z.sub prime y in
    write (i*2*width) x;
    write ((i*2+1)*width) y
  done;
  Printf.printf "let coordinates = %S\n" (Bytes.unsafe_to_string coordinates)
