open Cairovm

let () =
  let state = Random.State.make [| 86 |] in
  for i = 1 to 4096 do
    let value = Z.of_int (Random.State.bits state) in
    let p = if i mod 2 = 0 then Hints_secp.secp_p else Hints_secp.secp_n in
    let m = Z.sub value (Z.of_int 31) in
    if Z.sign m <> 0 then begin
      let q = Hints_secp.div_mod (Z.neg value) m p in
      assert (Z.sign q >= 0 && Z.lt q p);
      assert (Z.equal Z.(erem ((q * m) + value) p) Z.zero)
    end
  done;
  List.iter
    (fun m ->
      match Hints_secp.div_mod Z.one m (Z.of_int 21) with
      | exception Errors.Vm_error _ -> ()
      | _ -> failwith "expected div_mod to reject a non-invertible divisor")
    (List.map Z.of_int [ 0; 3; -7; 21 ])
