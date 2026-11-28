(* Blake2s compression and the blake2s hints (cairo-vm blake2s_hash.rs,
   blake2s_utils.rs). The Blake2s opcode extension reuses [compress]. *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

(* Blake2s uses SHA-256's initial hash value. *)
let iv = Sha256.iv

external compress_into : int array -> int array -> int -> int -> int -> int -> unit
  = "cvm_blake2s_byte" "cvm_blake2s" [@@noalloc]

external blake_u32_words : Felt.pool -> Felt.t -> int array -> int
  = "cvm_blake_u32_words" [@@noalloc]

let compress h msg t0 t1 f0 f1 =
  if Array.length h <> 8 || Array.length msg < 16 then fail "Invalid BLAKE2s block";
  let state = Array.copy h in
  compress_into state msg t0 t1 f0 f1;
  state

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
      else write_ap vm (of_bool (Felt.bits (int_at vm pv 0) <= 63)));
  reg C.blake2s_unpack_felts (fun c vm ->
      let n = get_z vm c "packed_values_len" in
      if Z.numbits n > 62 then fail "Felt %s does not fit a usize" (Z.to_string n);
      let pv = get_ptr vm c "packed_values" and out = get_ptr vm c "unpacked_u32s" in
      (* Snapshot every input before writing output: the two ranges can alias,
         and a missing input must fail before the first output assignment. *)
      let vals = List.init (Z.to_int n) (int_at vm pv) in
      let words = Array.make 8 0 and at = ref (Felt.roff out) in
      let seg = Felt.rseg out in
      List.iter (fun v ->
          let count = blake_u32_words Felt.pool v words in
          for i = 0 to count - 1 do
            write_checked vm seg !at (Felt.small words.(i));
            incr at
          done) vals);
  reg C.example_blake2s_compress (fun c vm ->
      let start = get_ptr vm c "blake2s_start" and out = get_ptr vm c "output" in
      let n_bytes = u32 (get_z vm c "n_bytes") in
      let msg = Array.init 16 (fun i -> u32 (z_at vm start i)) in
      let st = compress (modified_iv ()) msg n_bytes 0 0xffffffff 0 in
      write_arg vm out (smalls st))
