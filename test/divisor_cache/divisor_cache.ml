open Cairovm

let () =
  let z x = Felt.of_z x in
  let denoms = [Z.shift_left Z.one 190; Z.pred Felt.p; Z.of_int 3; Z.one; Z.zero] in
  for pass = 0 to 19 do
    List.iter (fun b ->
      for k = 0 to 100 do
        let n = Z.(add (shift_left (of_int (Stdlib.(1+pass))) 202) (of_int k)) in
        (* Recreate b to cover equal field values held in different slots. *)
        let result = Felt.div (z n) (z b) in
        if Z.equal b Z.zero then assert (result = None) else begin
          let expected = Z.erem Z.(mul n (invert b Felt.p)) Felt.p in
          assert (Z.equal (Felt.to_z (Option.get result)) expected)
        end
      done
    ) denoms
  done
