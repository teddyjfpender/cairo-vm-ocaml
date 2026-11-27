open Cairovm

let expect_error message f =
  match f () with
  | exception Vm.Vm_error actual -> assert (actual = message)
  | _ -> failwith "expected hint error"

let () =
  let base = Z.shift_left Z.one 86 in
  let split n =
    match Hints.split3 n with
    | [a; b; c] ->
        List.iter (fun v -> assert (Z.sign v >= 0 && Z.lt v base)) [a; b; c];
        assert (Z.equal n Z.(a + base * (b + base * c)))
    | _ -> assert false
  in
  let limit = Z.shift_left Z.one 258 in
  List.iter split Z.[zero; one; pred base; base; succ base; pred limit];
  List.iter (fun z -> expect_error "split: value too large" (fun () -> Hints.split3 z))
    [Z.minus_one; limit; Z.succ limit];
  let state = Random.State.make [|86|] in
  for i = 1 to 4096 do
    let value = Z.of_int (Random.State.bits state) in
    split (Z.extract (Z.shift_left value (i mod 255)) 0 258);
    let p = if i mod 2 = 0 then Hints.secp_p else Hints.secp_n in
    let m = Z.sub value (Z.of_int 31) in
    if Z.sign m <> 0 then begin
      let q = Hints.div_mod (Z.neg value) m p in
      assert (Z.sign q >= 0 && Z.lt q p);
      assert (Z.equal Z.(erem (q * m + value) p) Z.zero)
    end
  done;
  List.iter (fun m -> expect_error "div_mod: not invertible"
      (fun () -> Hints.div_mod Z.one m (Z.of_int 21))) (List.map Z.of_int [0; 3; -7; 21])
