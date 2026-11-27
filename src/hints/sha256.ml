(* SHA-256 compression and the sha256 hints (cairo-vm sha256_utils.rs). *)

open Errors
open Hintrt
module C = Hint_codes

let k =
  [| 0x428a2f98; 0x71374491; 0xb5c0fbcf; 0xe9b5dba5; 0x3956c25b; 0x59f111f1; 0x923f82a4; 0xab1c5ed5;
     0xd807aa98; 0x12835b01; 0x243185be; 0x550c7dc3; 0x72be5d74; 0x80deb1fe; 0x9bdc06a7; 0xc19bf174;
     0xe49b69c1; 0xefbe4786; 0x0fc19dc6; 0x240ca1cc; 0x2de92c6f; 0x4a7484aa; 0x5cb0a9dc; 0x76f988da;
     0x983e5152; 0xa831c66d; 0xb00327c8; 0xbf597fc7; 0xc6e00bf3; 0xd5a79147; 0x06ca6351; 0x14292967;
     0x27b70a85; 0x2e1b2138; 0x4d2c6dfc; 0x53380d13; 0x650a7354; 0x766a0abb; 0x81c2c92e; 0x92722c85;
     0xa2bfe8a1; 0xa81a664b; 0xc24b8b70; 0xc76c51a3; 0xd192e819; 0xd6990624; 0xf40e3585; 0x106aa070;
     0x19a4c116; 0x1e376c08; 0x2748774c; 0x34b0bcb5; 0x391c0cb3; 0x4ed8aa4a; 0x5b9cca4f; 0x682e6ff3;
     0x748f82ee; 0x78a5636f; 0x84c87814; 0x8cc70208; 0x90befffa; 0xa4506ceb; 0xbef9a3f7; 0xc67178f2 |]

let iv = [| 0x6A09E667; 0xBB67AE85; 0x3C6EF372; 0xA54FF53A; 0x510E527F; 0x9B05688C; 0x1F83D9AB; 0x5BE0CD19 |]

let compress (state : int array) (words : int array) =
  let w = Array.make 64 0 in
  Array.blit words 0 w 0 16;
  for i = 16 to 63 do
    let s0 = rotr w.(i - 15) 7 lxor rotr w.(i - 15) 18 lxor (w.(i - 15) lsr 3) in
    let s1 = rotr w.(i - 2) 17 lxor rotr w.(i - 2) 19 lxor (w.(i - 2) lsr 10) in
    w.(i) <- (w.(i - 16) + s0 + w.(i - 7) + s1) land m32
  done;
  let a = ref state.(0) and b = ref state.(1) and c = ref state.(2) and d = ref state.(3) in
  let e = ref state.(4) and f = ref state.(5) and g = ref state.(6) and h = ref state.(7) in
  for i = 0 to 63 do
    let s1 = rotr !e 6 lxor rotr !e 11 lxor rotr !e 25 in
    let ch = (!e land !f) lxor (lnot !e land m32 land !g) in
    let t1 = (!h + s1 + ch + k.(i) + w.(i)) land m32 in
    let s0 = rotr !a 2 lxor rotr !a 13 lxor rotr !a 22 in
    let maj = (!a land !b) lxor (!a land !c) lxor (!b land !c) in
    let t2 = (s0 + maj) land m32 in
    h := !g; g := !f; f := !e;
    e := (!d + t1) land m32;
    d := !c; c := !b; b := !a;
    a := (t1 + t2) land m32
  done;
  let out = [| !a; !b; !c; !d; !e; !f; !g; !h |] in
  Array.mapi (fun i v -> (state.(i) + v) land m32) out

(* Padded SHA-256 of a whole message (sha2::Sha256::digest). *)
let digest (msg : string) : string =
  let len = String.length msg in
  let padded_len = ((len + 9 + 63) / 64) * 64 in
  let b = Bytes.make padded_len '\000' in
  Bytes.blit_string msg 0 b 0 len;
  Bytes.set b len '\x80';
  Bytes.set_int64_be b (padded_len - 8) (Int64.of_int (len * 8));
  let h = ref iv in
  for blk = 0 to (padded_len / 64) - 1 do
    h := compress !h (Array.init 16 (fun i -> Int32.to_int (Bytes.get_int32_be b ((blk * 64) + (4 * i))) land m32))
  done;
  let out = Bytes.create 32 in
  Array.iteri (fun i v -> Bytes.set_int32_be out (4 * i) (Int32.of_int v)) !h;
  Bytes.to_string out

let register reg =
  reg C.sha256_input (fun c vm -> set_val vm c "full_word" (of_bool (Z.geq (get_z vm c "n_bytes") (z 4))));
  let sha256_main c vm iv =
    let start = get_ptr vm c "sha256_start" in
    let chunk = const_suffix c "SHA256_INPUT_CHUNK_SIZE_FELTS" in
    if Z.geq chunk (z 100) then fail "assert 0 <= _sha256_input_chunk_size_felts < 100";
    let chunk = Z.to_int chunk in
    let words = Array.init chunk (fun i -> u32 (z_at vm start i)) in
    (* sha2::compress256 takes exactly one 64-byte block *)
    if chunk <> 16 then fail "SHA256 block must be 16 words, got %d" chunk;
    let st = compress iv words in
    write_arg vm (get_ptr vm c "output") (smalls st)
  in
  reg C.sha256_main_constant_input_length (fun c vm -> sha256_main c vm iv);
  reg C.sha256_main_arbitrary_input_length (fun c vm ->
      let state = get_ptr vm c "state" in
      let size = const_suffix c "SHA256_STATE_SIZE_FELTS" in
      if Z.geq size (z 100) then fail "assert 0 <= _sha256_state_size_felts < 100";
      if not (Z.equal size (z 8)) then fail "Invalid value for SHA256_STATE_SIZE_FELTS: %s, expected 8" (Z.to_string size);
      let iv = Array.init 8 (fun i -> u32 (z_at vm state i)) in
      sha256_main c vm iv);
  reg C.sha256_finalize (fun c vm ->
      let output = compress iv (Array.make 16 0) in
      let one = List.init 16 (fun _ -> Felt.zero) @ smalls iv @ smalls output in
      (* cairo-vm hard-codes BLOCK_SIZE = 7 *)
      write_arg vm (get_ptr vm c "sha256_ptr_end") (List.concat (List.init 6 (fun _ -> one))))
