open Cairovm

(* Values produced by the pinned sequencer's polynomial_coefficients_to_kzg_commitment,
   which FFTs the coefficients and uses c-kzg's blob commitment. *)
let cases = [
  1, false, "0x4715ccd372e1e40cab95517779d840416e1679c84a6db24e", "0x851f8a0b82a6d86202a61cbc3b0f3db7d19650b914587bde";
  17, false, "0x6d5634c390ea5cc5e918ba316d83e797dcf2a650a081bdf0", "0x96424ad8c0a260aea5c82a57e09cda5dba9efe561b7cc3bd";
  193, false, "0x54686b762761ff92b1039b6d98b147d3e33a2e518eb410da", "0x91d7cf94aff1296842c63a8e239e73dd1ce1c776496ea061";
  4096, true, "0x70ccaa78d45b4a2c2c096dd795931d3c593ed6b0eac4b46", "0x9060fb39a220a34223f1cfeffa7057027676f10dc02078ef";
  4096, false, "0x214b1fdf23f286a400d5f156739aaae6969ee9534235447d", "0x8b496df7eadb9e64da74139bbb394df234953f13a7bdac7a";
 ]

let () =
  List.iter (fun (n, sparse, lo, hi) ->
      let coefficients = Array.init n (fun i ->
          if sparse && i <> n - 1 then Z.zero else Z.of_int (i * 987654321 + 13)) in
      let a, b = Os_kzg.commit coefficients in
      assert (Z.equal (Felt.to_z a) (Z.of_string lo));
      assert (Z.equal (Felt.to_z b) (Z.of_string hi))) cases;
  let low, high = Os_kzg.commit [|Z.zero|] in
  assert (low = Felt.zero && Z.equal (Felt.to_z high) (Z.shift_left (Z.of_int 3) 190))

(* Exercise each window boundary with coefficients spanning the full input width. *)
let () =
  let random = Random.State.make [|314159|] in
  let coefficient i =
    if i mod 7 = 0 then Z.zero
    else Z.of_bits (String.init 32 (fun _ -> Char.chr (Random.State.int random 256))) in
  List.iter (fun n ->
      let inputs = Array.init n coefficient in
      let lo, hi = Os_kzg.commit inputs in
      let expected_lo, expected_hi = Os_kzg.commit_reference inputs in
      assert (Felt.equal lo expected_lo && Felt.equal hi expected_hi))
    [0; 1; 31; 32; 191; 192; 639; 640]
