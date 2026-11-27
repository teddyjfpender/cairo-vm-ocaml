open Cairovm

let () =
  let open Z in
  let near x = [pred x; x; succ x] in
  let values = zero :: pred Felt.p ::
    List.concat_map (fun bits -> near (shift_left one bits)) [59; 64; 86; 123; 125; 126; 127; 128; 192; 250] in
  List.iter (fun a -> List.iter (fun b ->
    let actual = Felt.to_z (Felt.mul (Felt.of_z a) (Felt.of_z b)) in
    assert (equal actual (erem (mul a b) Felt.p))) values) values;
  (* cairo-lang 0.13.5 poseidon_perm, exercising the dedicated squaring path. *)
  let input = [|pred (shift_left one 64); shift_left one 128; pred (shift_left one 192)|] in
  let expected = [|
    "3143462494722694901530010734682287541125050686376976807021414893039064445917";
    "1603826836212970325138872328357199913552440906838477977392066201135652874471";
    "3088490997232510509292976764898145315928397103844479806610460482157694621314";
  |] in
  let output = Felt.poseidon (Array.map Felt.of_z input) in
  Array.iteri (fun i want -> assert (equal (Felt.to_z output.(i)) (of_string want))) expected

let () =
  let rng = Random.State.make [| 125; 251 |] in
  let word () =
    let rec build n acc = if n = 0 then acc else
      build (n-1) Z.(logor (shift_left acc 16) (of_int (Random.State.int rng 65536))) in
    build 8 Z.zero in
  for _ = 1 to 2048 do
    let a = word () and b = word () in
    let result = Felt.mul (Felt.of_z a) (Felt.of_z b) in
    assert (Z.equal (Felt.to_z result) (Z.erem (Z.mul a b) Felt.p))
  done
