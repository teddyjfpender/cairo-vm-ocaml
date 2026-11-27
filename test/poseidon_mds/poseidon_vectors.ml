open Cairovm

let permute input =
  Array.iteri (fun i z ->
    let value = Felt.of_z z in Felt.c_load_slot !Felt.pool value i) input;
  Felt.c_poseidon !Felt.pool 0 3;
  Array.init 3 (fun i ->
    Felt.reserve 1;
    let code = Felt.c_code_of_slot !Felt.pool (3+i) !Felt.pool_n in
    Felt.commit code; Felt.to_z code)

(* Expected results from cairo-lang 0.13.5 poseidon_perm. *)
let check input expected =
  let array = Array.map Z.of_string in
  assert (permute (array input) = array expected)

let () =
  check [|"0x0"; "0x0"; "0x0"|]
    [|"0x79e8d1e78258000a28fc9d49e233bc6852357968577b1e386550ed6a9086133"; "0x3840d003d0f3f96dbb796ff6aa6a63be5b5404b91ccaabca256154cbb6fb984"; "0x1eb39da3f7d3b04142d0ac83d9da00c9325a61fb2ef326e50b70eaa8a3c7cc7"|];
  check [|"0x800000000000011000000000000000000000000000000000000000000000000"; "0x800000000000011000000000000000000000000000000000000000000000000"; "0x800000000000011000000000000000000000000000000000000000000000000"|]
    [|"0x5a5f2203787ca729e974a3156ebf02128c355cebc22cb6371c94c6d8eb1b78"; "0x323000fe60b1ef090b2301b817be26aaf097e9aa3390daeee7466f7bf85850e"; "0x1670112bd02cdc30ea05e8a310389ac1f61c2fcf5f645db052a8bddc9a6df7a"|];
  check [|"0x0"; "0x800000000000011000000000000000000000000000000000000000000000000"; "0x1"|]
    [|"0x6dd090d7085884146280f4d7aa2db4f30cf16e5196babdec726e8015f596642"; "0x6eac1af9d9c49f6a94197d3131c176c54cf0978b34d5acf24ff659a80c48202"; "0x227f67199c3dcfb211be7dd778e5c18f6002859337b3fdc0d13e9f13e502546"|];
  check [|"0x1"; "0x2"; "0x3"|]
    [|"0xfa8c9b6742b6176139365833d001e30e932a9bf7456d009b1b174f36d558c5"; "0x4f04deca4cb7f9f2bd16b1d25b817ca2d16fba2151e4252a2e2111cde08bfe6"; "0x58dde0a2a785b395ee2dc7b60b79e9472ab826e9bb5383a8018b59772964892"|];
  (* Cycle all three lanes through distinct full-width inputs. *)
  let state = ref Z.one and checksum = Array.make 3 Z.zero in
  let next () =
    state := Z.erem (Z.add (Z.mul !state (Z.of_int 48271)) (Z.of_int 197)) Felt.p;
    !state
  in
  for _ = 1 to 1024 do
    let result = permute (Array.init 3 (fun _ -> next ())) in
    Array.iteri (fun i z -> checksum.(i) <- Z.erem (Z.add checksum.(i) z) Felt.p) result
  done;
  assert (checksum = Array.map Z.of_string
    [|"0x5a5878cc3a51f2922b47ad420539762325459a949b9902648b0f12cc5d89a19"; "0x7e41202d4e2b0d0b9209395b733bb0516010012da10089a1fe1e278548e41c5"; "0x64db2a63c9e11fd8674d792fd496405a719f9ee6339bc6839c8b4188f6f5fdc"|])
