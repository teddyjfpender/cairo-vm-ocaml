open Cairovm

(* Expected hashes from cairo-lang 0.13.5 fast_pedersen_hash. *)
let check x y expected =
  let felt s = Felt.of_z (Z.of_string s) in
  let x = felt x and y = felt y in
  let result = Felt.pedersen x y in
  assert (Z.equal (Felt.to_z result) (Z.of_string expected))

let () =
  check "0x0" "0x0"
    "0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804";
  check "0x1" "0x2"
    "0x5bb9440e27889a364bcb678b1f679ecd1347acdedcbf36e83494f857cc58026";
  check "0x100000000000000000000000000000000000000000000000000000000000000" "0x0"
    "0x8373a6e44974818256b1f685dc494e55dc0340a1e9d259a38bed3915323ed";
  check "0x0" "0x700000000000000000000000000000000000000000000000000000000000000"
    "0x2b099e4ea4b5345204b14a6288948ac6763534f150e7d5baeced163ff9b2f20";
  check "0x800000000000011000000000000000000000000000000000000000000000000" "0x800000000000011000000000000000000000000000000000000000000000000"
    "0x7258fccaf3371fad51b117471d9d888a1786c5694c3e6099160477b593a576e";
  check "0xff0000000000000000000000000000000000000000000000" "0xff000000000000000000000000000000000000000000000000000000000000"
    "0x7be86b0e9335f59caeaca49e20fa7ffe87f738bae6312acefdd800659448ff5";
  check "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "0xff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
    "0x21a8cb0e898b93a376be79f20a3d545e77e42ec9282e7589b9eeabd60110768"

(* Same namespace, changed suffix, then a switched namespace and a revisit. *)
let () =
  check "0x10000000000000000000000000000000000000000000000000000000000000d" "0x2000000000000000000000000000029"
    "0x7f45348483482bc75fcb6acb5fc949efb29ef24c202590a226cca5a1868ebf1";
  check "0x10000000000000000000000000000000000000000000000000000000000000d" "0x61"
    "0x508924e68e1273cbeed84bd4c562f0fe91a3aad265d114742ca5c83f7a8096b";
  check "0x0" "0x2000000000000000000000000000029"
    "0x6a401dd57da3a93a3e25abffc0f7b273c6264dba78b3a63a89ac1201180abad";
  check "0x10000000000000000000000000000000000000000000000000000000000000d" "0x61"
    "0x508924e68e1273cbeed84bd4c562f0fe91a3aad265d114742ca5c83f7a8096b"

(* Compare a dependent chain against cairo-lang's independent Pedersen
   implementation. Alternate high and low field elements across all limbs. *)
let () =
  let p = Z.(add (shift_left one 251) (add (shift_left (of_int 17) 192) one)) in
  let x = ref Felt.zero in
  for i = 0 to 255 do
    let bit = (i * 67) mod 252 and small = i * 65537 in
    let y = Z.(erem (add (shift_left one bit) (of_int small)) p) in
    let y = if i mod 2 = 0 then y else Z.(sub (pred p) y) in
    x := Felt.pedersen !x (Felt.of_z y)
  done;
  assert (Z.equal (Felt.to_z !x)
    (Z.of_string "0x7459297c2898494cb4b0192e17f7f50662dcae04ee6de87dbc7d8270d62e50e"))

external batch_pedersen_cache : bool -> bool = "cvm_batch_pedersen_cache" [@@noalloc]

(* Give every pair the same set index while varying both middle limbs. Restart
   the VM's temporary slots before each replay, including after eviction. *)
let () =
  let pairs = Array.init 12 (fun i ->
      Z.(add one (shift_left (of_int Stdlib.(i + 1)) 64)),
      Z.(add (of_int 2) (shift_left (of_int Stdlib.(i + 2)) 128))) in
  let hash (x, y) = Felt.with_temporary_slots (fun () ->
      Felt.to_z (Felt.pedersen (Felt.of_z x) (Felt.of_z y))) in
  let expected = Array.map hash pairs in
  let previous = batch_pedersen_cache true in
  Fun.protect ~finally:(fun () -> ignore (batch_pedersen_cache previous)) (fun () ->
      List.iter (fun i -> assert (Z.equal (hash pairs.(i)) expected.(i)))
        [0; 1; 2; 3; 2; 0; 4; 5; 6; 7; 2; 8; 9; 10; 11; 3; 0])

let () =
  let words = Array.init 256 (fun i ->
      let bit = (i * 67) mod 252 and small = i * 65537 in
      let y = Z.(erem (add (shift_left one bit) (of_int small)) Felt.p) in
      if i mod 2 = 0 then y else Z.(sub (pred Felt.p) y)) in
  let classes ws = `Assoc ["0x123", `Assoc ["program", `Assoc ["data", `List ws]]] in
  let strings = List.map (fun w -> `String (Z.to_string w)) (Array.to_list words) in
  let module Prepared = Legacy_class.Prepared in
  assert (Prepared.start (classes [`String "0x1"]) = None);
  assert (Prepared.start (classes (`String "-1" :: strings)) = None);
  if not Sys.big_endian then begin
    let pending = Option.get (Prepared.start (classes strings)) in
    assert (Prepared.install pending "0x124" = None);
    let other = Felt.of_z Z.(add words.(0) (shift_left one 192)) in
    let expected_other = Felt.pedersen Felt.zero other in
    let old = Option.get (Prepared.install pending "0x123") in
    Fun.protect ~finally:(fun () -> ignore (batch_pedersen_cache old)) (fun () ->
        assert (Felt.equal (Felt.pedersen Felt.zero other) expected_other);
        let final = Array.fold_left (fun h w -> Felt.pedersen h (Felt.of_z w)) Felt.zero words in
        assert (Z.equal (Felt.to_z final)
          (Z.of_string "0x7459297c2898494cb4b0192e17f7f50662dcae04ee6de87dbc7d8270d62e50e")))
  end

external batch_pedersen_cache_active : unit -> bool = "cvm_batch_pedersen_cache_active" [@@noalloc]

let () =
  List.iter (fun initial ->
      let previous = batch_pedersen_cache initial in
      Fun.protect ~finally:(fun () -> ignore (batch_pedersen_cache previous)) (fun () ->
          let fail_in_hint _ = ignore (batch_pedersen_cache (not initial)); raise Exit in
          (match Cpu.run ~steps:1 (Vm.create ~trace:false) [|[|fail_in_hint|]|] with
           | () -> assert false
           | exception Exit -> ());
          assert (batch_pedersen_cache_active () = initial))) [false; true]
