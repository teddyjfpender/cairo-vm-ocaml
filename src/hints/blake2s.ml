(* Blake2s compression and the blake2s hints (cairo-vm blake2s_hash.rs,
   blake2s_utils.rs). The Blake2s opcode extension reuses [compress]. *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

(* Blake2s uses SHA-256's initial hash value. *)
let iv = Sha256.iv

let sigma =
  [|
    [| 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15 |];
    [| 14; 10; 4; 8; 9; 15; 13; 6; 1; 12; 0; 2; 11; 7; 5; 3 |];
    [| 11; 8; 12; 0; 5; 2; 15; 13; 10; 14; 3; 6; 7; 1; 9; 4 |];
    [| 7; 9; 3; 1; 13; 12; 11; 14; 2; 6; 5; 10; 4; 0; 15; 8 |];
    [| 9; 0; 5; 7; 2; 4; 10; 15; 14; 1; 11; 12; 6; 8; 3; 13 |];
    [| 2; 12; 6; 10; 0; 11; 8; 3; 4; 13; 7; 5; 15; 14; 1; 9 |];
    [| 12; 5; 1; 15; 14; 13; 4; 10; 0; 7; 6; 3; 9; 2; 8; 11 |];
    [| 13; 11; 7; 14; 12; 1; 3; 9; 5; 0; 15; 4; 8; 6; 2; 10 |];
    [| 6; 15; 14; 9; 11; 3; 0; 8; 12; 2; 13; 7; 1; 4; 10; 5 |];
    [| 10; 2; 8; 4; 7; 6; 1; 5; 15; 11; 9; 14; 3; 12; 13; 0 |];
  |]

let compress (h : int array) (msg : int array) t0 t1 f0 f1 =
  let s = Array.make 16 0 in
  Array.blit h 0 s 0 8;
  Array.blit iv 0 s 8 4;
  s.(12) <- (iv.(4) lxor t0) land m32;
  s.(13) <- (iv.(5) lxor t1) land m32;
  s.(14) <- (iv.(6) lxor f0) land m32;
  s.(15) <- (iv.(7) lxor f1) land m32;
  let mix a b c d m0 m1 =
    s.(a) <- (s.(a) + s.(b) + m0) land m32;
    s.(d) <- rotr (s.(d) lxor s.(a)) 16;
    s.(c) <- (s.(c) + s.(d)) land m32;
    s.(b) <- rotr (s.(b) lxor s.(c)) 12;
    s.(a) <- (s.(a) + s.(b) + m1) land m32;
    s.(d) <- rotr (s.(d) lxor s.(a)) 8;
    s.(c) <- (s.(c) + s.(d)) land m32;
    s.(b) <- rotr (s.(b) lxor s.(c)) 7
  in
  for r = 0 to 9 do
    let sg = sigma.(r) in
    let m i = msg.(sg.(i)) in
    mix 0 4 8 12 (m 0) (m 1);
    mix 1 5 9 13 (m 2) (m 3);
    mix 2 6 10 14 (m 4) (m 5);
    mix 3 7 11 15 (m 6) (m 7);
    mix 0 5 10 15 (m 8) (m 9);
    mix 1 6 11 12 (m 10) (m 11);
    mix 2 7 8 13 (m 12) (m 13);
    mix 3 4 9 14 (m 14) (m 15)
  done;
  Array.init 8 (fun i -> h.(i) lxor s.(i) lxor s.(8 + i))

let to_u32 v =
  let n = Felt.to_nat v in
  if n < 0 || n > m32 then fail "blake2s: value is not a 32-bit word";
  n

let modified_iv () = let v = Array.copy iv in v.(0) <- v.(0) lxor 0x01010020; v

let register reg =
  (* The bootloader's Blake encoder splits every third word at successive
     byte boundaries before packing it into 32-bit limbs. *)
  for bytes = 1 to 7 do
    let index = 3 * bytes in
    let high = Printf.sprintf "high%d" index and low = Printf.sprintf "low%d" index in
    let divisor = if bytes = 1 then "256" else Printf.sprintf "256 ** %d" bytes in
    let code = Printf.sprintf "ids.%s, ids.%s = divmod(memory[ids.felt_array + %d], %s)"
        high low index divisor in
    reg code (fun c vm ->
        let word = z_at vm (get_ptr vm c "felt_array") index in
        let bits = 8 * bytes in
        set_int vm c high (Z.shift_right word bits);
        set_int vm c low (Z.extract word 0 bits))
  done;
  reg C.blake2s_compute (fun c vm ->
      let out = get_ptr vm c "output" in
      let at k = mem_at vm (Felt.reloc (Felt.rseg out) 0) (Felt.roff out + k) in
      let h = Array.init 8 (fun i -> to_u32 (at (i - 26))) in
      let msg = Array.init 16 (fun i -> to_u32 (at (i - 18))) in
      let t = to_u32 (at (-2)) and f = to_u32 (at (-1)) in
      let r = compress h msg t 0 f 0 in
      write_arg vm out (Array.to_list (Array.map Felt.small r)));
  (* blake2s finalize padding *)
  reg C.blake2s_finalize (fun c vm ->
      let n = Z.to_int (const_z c "N_PACKED_INSTANCES") in
      check (0 <= n && n < 20) "N_PACKED_INSTANCES out of range";
      let sz = Z.to_int (const_z c "INPUT_BLOCK_FELTS") in
      check (0 <= sz && sz < 100) "INPUT_BLOCK_FELTS out of range";
      let message = Array.make sz 0 in
      let miv = Array.copy iv in
      miv.(0) <- iv.(0) lxor 0x01010020;
      let output = compress miv (Array.append message (Array.make (max 0 (16 - sz)) 0)) 0 0 0xffffffff 0 in
      let one = Array.to_list miv @ Array.to_list message @ [ 0; 0xffffffff ] @ Array.to_list output in
      let pad = List.concat (List.init (n - 1) (fun _ -> one)) in
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (List.map Felt.small pad));
  let blake_words low high rev =
    let w v i = Z.to_int (Z.logand (Z.shift_right v (32 * i)) (z m32)) in
    if rev then (List.init 4 (fun i -> w high (3 - i)), List.init 4 (fun i -> w low (3 - i)))
    else (List.init 4 (fun i -> w low i), List.init 4 (fun i -> w high i))
  in
  reg C.blake2s_add_uint256 (fun c vm ->
      let a, b = blake_words (get_z vm c "low") (get_z vm c "high") false in
      let d = get_ptr vm c "data" in
      write_arg vm d (List.map Felt.small a);
      write_arg vm (value_add d (Felt.small 4)) (List.map Felt.small b));
  reg C.blake2s_add_uint256_bigend (fun c vm ->
      let a, b = blake_words (get_z vm c "low") (get_z vm c "high") true in
      let d = get_ptr vm c "data" in
      write_arg vm d (List.map Felt.small a);
      write_arg vm (value_add d (Felt.small 4)) (List.map Felt.small b));
  let finalize_padding ~message_first =
    let miv = modified_iv () and message = Array.make 16 0 in
    let output = compress miv message 0 0 0xffffffff 0 in
    let one =
      (if message_first then Array.to_list message @ Array.to_list miv else Array.to_list miv @ Array.to_list message)
      @ [ 0; 0xffffffff ] @ Array.to_list output
    in
    (* cairo-vm hard-codes N_PACKED_INSTANCES = 7 *)
    List.map Felt.small (List.concat (List.init 6 (fun _ -> one)))
  in
  reg C.blake2s_finalize_v2 (fun c vm ->
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (finalize_padding ~message_first:false));
  reg C.blake2s_finalize_v3 (fun c vm ->
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (finalize_padding ~message_first:true));
  reg C.is_less_than_63_bits_and_not_end (fun c vm ->
      let e = get_ptr vm c "end" and pv = get_ptr vm c "packed_values" in
      if Felt.equal e pv then write_ap vm Felt.zero
      else write_ap vm (of_bool (Z.lt (z_at vm pv 0) (two_pow 63))));
  reg C.blake2s_unpack_felts (fun c vm ->
      let n = get_z vm c "packed_values_len" in
      if Z.numbits n > 62 then fail "Felt %s does not fit a usize" (Z.to_string n);
      let pv = get_ptr vm c "packed_values" and out = get_ptr vm c "unpacked_u32s" in
      let vals = List.init (Z.to_int n) (fun i -> z_at vm pv i) in
      let limbs v =
        if Z.lt v (two_pow 63) then [ Z.shift_right v 32; Z.logand v (z m32) ]
        else
          let v = Z.add v (two_pow 255) in
          List.init 8 (fun i -> Z.logand (Z.shift_right v (32 * (7 - i))) (z m32))
      in
      write_arg vm out (List.map Felt.of_z (List.concat_map limbs vals)));
  reg C.example_blake2s_compress (fun c vm ->
      let start = get_ptr vm c "blake2s_start" and out = get_ptr vm c "output" in
      let n_bytes = u32 (get_z vm c "n_bytes") in
      let msg = Array.init 16 (fun i -> u32 (z_at vm start i)) in
      let st = compress (modified_iv ()) msg n_bytes 0 0xffffffff 0 in
      write_arg vm out (smalls st))
