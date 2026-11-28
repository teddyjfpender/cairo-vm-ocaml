(* Short Weierstrass curves with a = 0 or a = -3. Public-input point
   operations use Jacobian coordinates (X/Z^2,Y/Z^3) internally. *)
module Make (C : sig val prime : Z.t val minus_three : bool end) = struct
  let p = C.prime
  let modulo x = Z.erem x p
  (* Coordinates and field products are canonical, so a sum or difference
     needs at most one correction. *)
  let add x y =
    let z = Z.add x y in
    if Z.geq z p then Z.sub z p else z
  let sub x y =
    let z = Z.sub x y in
    if Z.sign z < 0 then Z.add z p else z
  let mul x y = modulo (Z.mul x y)
  let square x = mul x x
  let twice x = add x x

  type point = Infinity | Jacobian of Z.t * Z.t * Z.t

  let double = function
    | Infinity -> Infinity
    | Jacobian (_,y,_) when Z.equal y Z.zero -> Infinity
    | Jacobian (x,y,z) ->
        let yy = square y in
        let slope = if C.minus_three then begin
            let zz = square z in mul (sub x zz) (add x zz)
          end else square x in
        let s = twice (twice (mul x yy)) and m = add slope (twice slope) in
        let x' = sub (square m) (twice s) in
        let y' = sub (mul m (sub s x')) (twice (twice (twice (square yy)))) in
        Jacobian (x', y', twice (mul y z))

  (* Add by first expressing both affine numerators over the same denominator. *)
  let combine left u1 s1 u2 s2 z =
    let h = sub u2 u1 and r = sub s2 s1 in
    if Z.equal h Z.zero then (if Z.equal r Z.zero then double left else Infinity)
    else
      let hh = square h in
      let hhh = mul h hh and v = mul u1 hh in
      let x = sub (sub (square r) hhh) (twice v) in
      Jacobian (x, sub (mul r (sub v x)) (mul s1 hhh), mul h z)

  let add_point a b = match a, b with
    | Infinity, p | p, Infinity -> p
    | Jacobian (x,y,z), Jacobian (xx,yy,zz) ->
        let z2 = square z and zz2 = square zz in
        combine a (mul x zz2) (mul y (mul zz zz2)) (mul xx z2) (mul yy (mul z z2)) (mul z zz)

  let mixed a (x,y) = match a with
    | Infinity -> Jacobian (x,y,Z.one)
    | Jacobian (xx,yy,z) ->
        let z2 = square z in
        combine a xx yy (mul x z2) (mul y (mul z z2)) z

  let affine = function
    | Infinity -> None
    | Jacobian (x,y,z) ->
        let zi = Z.invert z p in
        let zz = square zi in
        Some (mul x zz, mul y (mul zi zz))

  let scale (x,y) scalar =
    let base = Jacobian (x,y,Z.one) in
    let table = Array.make 16 Infinity in
    table.(1) <- base;
    for i = 2 to 15 do
      table.(i) <- if i land 1 = 0 then double table.(i/2) else mixed table.(i-1) (x,y)
    done;
    let result = ref Infinity in
    for j = (Z.numbits scalar + 3)/4 - 1 downto 0 do
      for _ = 1 to 4 do result := double !result done;
      let digit = Z.to_int (Z.extract scalar (4*j) 4) in
      if digit <> 0 then result := add_point !result table.(digit)
    done;
    affine !result
end
