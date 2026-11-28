open Cairovm

let hex s = Z.of_string ("0x" ^ s)

let check curve scale generator order =
  let open Os_secp in
  let state = Random.State.make [|7120|] in
  let rand () = Z.of_bits (String.init 32 (fun _ -> Char.chr (Random.State.int state 256))) in
  let check point scalar =
    let x,y = point in
    let expected = match scale point scalar with Some (x,y) -> Point (x,y) | None -> Infinity in
    assert (multiply curve (Point (x,y)) scalar = expected);
    if use_native_curve then begin
      let out = Bytes.create 64 in
      let status = native_scale (curve == r1) (Z.to_bits x) (Z.to_bits y) (Z.to_bits scalar) out in
      assert (status = (if expected = Infinity then 0 else 1))
    end in
  List.iter (check generator) [Z.zero; Z.one; Z.pred order; order; Z.succ order; Z.pred (Z.shift_left Z.one 256)];
  for _ = 1 to 48 do
    let point = Option.get (scale generator (rand ())) in
    check point (rand ())
  done

let () =
  check Os_secp.k1 Os_secp.K1.scale
    (hex "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
     hex "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")
    (hex "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
  check Os_secp.r1 Os_secp.R1.scale
    (hex "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
     hex "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
    (hex "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
