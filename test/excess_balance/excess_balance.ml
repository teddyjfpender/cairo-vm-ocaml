open Cairovm
module D = Excess_balance.Dec

let z = Z.of_string
let equal x y = let a, b, _ = D.align x y in Z.equal a b
let some x = function Some y -> equal x y | None -> false

let () =
  (* excess_balance.rs test_imf *)
  let p = D.{ base = (z "5000000", 8); factor = (z "20000", 8); mmf = (z "50000000", 8); shift = (z "20000000000000", 8) } in
  assert (some (z "101784080000", 12) (D.imf p (z "4590000000000000000000", 16)));
  assert (some p.base (D.imf p (z "1", 8)));
  (* scale above 28 rounds half to even on the exact value *)
  assert (some (z "2", 28) (D.norm (z "25", 29)));
  assert (some (z "-4", 28) (D.norm (z "-35", 29)));
  assert (some (z "3", 28) (D.norm (z "2500000001", 37)));
  (* the mantissa stays below 2^96, dropping digits only while the scale allows *)
  let max = Z.pred D.limit in
  assert (some (max, 0) (D.norm (max, 0)));
  assert (D.norm (D.limit, 0) = None);
  assert (some (Z.div (Z.add D.limit (Z.of_int 4)) (Z.of_int 10), 0) (D.add (max, 1) (Z.one, 1)));
  assert (D.mul (max, 0) (Z.of_int 2, 0) = None);
  (* felt_to_scaled_decimal accepts exactly the 96-bit signed range *)
  assert (some (Z.neg max, 8) (D.of_felt (Felt.of_z (Z.sub Felt.p max))));
  assert (D.of_felt (Felt.of_z D.limit) = None);
  assert (D.to_felt (z "-15", 9) = Some (Felt.of_z (Z.sub Felt.p Z.one)))
