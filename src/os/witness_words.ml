external count : string -> int = "cvm_witness_words_count" [@@noalloc]
external load : string -> Felt.t array -> Felt.pool -> int -> int =
  "cvm_witness_words_load" [@@noalloc]

let decode raw =
  if String.length raw < 4 then Errors.fail "Truncated packed bytecode";
  let n = Int32.to_int (String.get_int32_be raw 0) in
  if n < 0 || n > 4 lsl 20 || n > String.length raw - 4 then Errors.fail "Invalid packed word count";
  let words = Array.make n Felt.zero in
  let next = load raw words Felt.pool !(Felt.pool_n) in
  if next = -2 then raise Out_of_memory;
  if next < 0 then Errors.fail "Invalid packed bytecode";
  Felt.pool_n := next;
  words

let encode xs =
  let n = List.length xs in
  if n > 4 lsl 20 then Errors.fail "Packed word count exceeds limit";
  let b = Buffer.create (4 + min (8 * n) 65536) in
  Buffer.add_int32_be b (Int32.of_int n);
  List.iter (fun x ->
      let z = Pie_file.z_of_json x in
      if Z.sign z < 0 || Z.geq z Felt.p then Errors.fail "OS input field element out of range";
      let width = (Z.numbits z + 7) / 8 in
      Buffer.add_uint8 b width;
      if width > 0 then Buffer.add_substring b (Z.to_bits z) 0 width) xs;
  Buffer.contents b
