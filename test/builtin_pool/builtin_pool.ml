open Cairovm

let () =
  (* Put the workspace across the next pool growth boundary. Include both
     small and big results so source and committed slot offsets diverge. *)
  let big = Felt.of_z (Z.shift_left Z.one 190) in
  while !Felt.pool_n < Bytes.length !Felt.pool / 32 - 1 do
    ignore (Felt.of_z (Z.shift_left Z.one 180))
  done;
  let start = !Felt.pool_n in
  Felt.reserve 16;
  let words = [|Felt.zero; big; Felt.one; big; big; Felt.zero; big; Felt.one|] in
  Array.iteri (fun i v -> Felt.c_load_slot !Felt.pool v (start + 8 + i)) words;
  let b : Vm.builtin = { kind = Vm.Keccak; base = 0; included = true;
                         stop_ptr = 0; cache = [||] } in
  Vm.cache_outputs b 8 (start + 8) 8;
  assert (!Felt.pool_n = start + 4);
  Array.iteri (fun i v -> assert (Felt.equal (Vm.cache_get b (8 + i)) v)) words
