(* The field kernel agrees with the Zarith reference on floor residues,
   exact quotients, inverses and limb splits. *)
open Cairovm
module F = Secp_field
module S = Hints_secp

let () =
  let st = Random.State.make [| 256 |] in
  let rand bits = Z.of_bits (String.init ((bits + 7) / 8) (fun _ -> Char.chr (Random.State.int st 256))) in
  let moduli = [ S.secp_p; S.secp_n; S.r1_p; S.secp_p_v2; Z.of_int 2; Z.of_int 21; Z.of_int 1024; Z.pred (Z.shift_left Z.one 256) ] in
  List.iter
    (fun p ->
      let m = Option.get (F.modulus p) in
      let eq t z = assert (Z.equal (F.to_z t) z) in
      for i = 1 to 2000 do
        (* limbs: small, 86-bit, and arbitrary signed felts *)
        let limb () = Felt.of_z (match i mod 3 with 0 -> Z.of_int (Random.State.int st 1000 - 500) | 1 -> rand 86 | _ -> rand 260) in
        let l = Array.init 3 (fun _ -> limb ()) in
        let v = S.pack86_l l 0 in
        eq (F.pack m l.(0) l.(1) l.(2)) (S.mod_floor v p);
        (match F.exact_quotient m l.(0) l.(1) l.(2) with
         | Some q -> assert (Z.sign (S.mod_floor v p) = 0 && Felt.equal q (Felt.of_z (Z.div v p)))
         | None -> assert (Z.sign (S.mod_floor v p) <> 0 || Z.numbits p < 192));
        let q = Z.mul p (Z.sub (rand 100) (Z.shift_left Z.one 99)) in
        let ql = List.map Felt.of_z [ Z.extract q 0 86; Z.extract q 86 86; Z.shift_right q 172 ] in
        (match ql with
         | [ a; b; c ] when Z.numbits p > 192 -> assert (Option.map Felt.to_signed_z (F.exact_quotient m a b c) = Some (Z.div q p))
         | _ -> ());
        let a = rand 256 and b = rand (if i mod 5 = 0 then 8 else 256) in
        let fa = F.of_z a and fb = F.of_z b in
        eq (F.add m fa fb) (S.mod_floor (Z.add a b) p);
        eq (F.sub m fa fb) (S.mod_floor (Z.sub a b) p);
        eq (F.mul m fa fb) (S.mod_floor (Z.mul a b) p);
        (match F.div m fa fb with
         | Some r -> eq r (S.div_mod a b p)
         | None -> assert (match S.div_mod a b p with exception Errors.Vm_error _ -> true | _ -> false));
        let limbs = List.init 3 (fun k -> Felt.to_z (F.limb86 fa k)) in
        assert (limbs = [ Z.extract a 0 86; Z.extract a 86 86; Z.extract a 172 86 ])
      done)
    moduli;
  assert (F.modulus Z.one = None && F.modulus (Z.shift_left Z.one 256) = None && F.modulus Z.minus_one = None)
