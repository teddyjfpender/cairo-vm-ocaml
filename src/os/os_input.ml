open Errors

let felt_slow j =
  let z = Pie_file.z_of_json j in
  if Z.sign z < 0 || Z.geq z Felt.p then fail "OS input field element out of range";
  Felt.of_z z

let felt = function
  | `Int i when i >= 0 -> Felt.of_int i
  | `String s as j -> (match Felt.of_hex_opt s with Some value -> value | None -> felt_slow j)
  | j -> felt_slow j
