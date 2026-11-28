open Errors

let felt_slow j =
  let z = Pie_file.z_of_json j in
  if Z.sign z < 0 || Z.geq z Felt.p then fail "OS input field element out of range";
  Felt.of_z z

let felt = function
  | `Int i when i >= 0 -> Felt.of_int i
  | `String s as j -> (match Felt.of_hex_opt s with Some value -> value | None -> felt_slow j)
  | j -> felt_slow j

external word_count : string -> int * int -> int = "cvm_hex_array_count" [@@noalloc]
external decode_hex : Felt.pool -> string -> Felt.t array -> int -> int * int -> int = "cvm_hex_array_parse" [@@noalloc]

(* A failed speculative decode leaves the pool cursor unchanged. The general
   JSON reader handles escaped strings, decimal words and empty arrays. *)
let decode_words raw ((first, last) as bounds) =
  let fallback () =
    let source = if first = 0 && last = String.length raw then raw
      else String.sub raw first (last - first) in
    Array.of_list (List.map felt (Yojson.Safe.Util.to_list (Json_reader.from_string source))) in
  let count = word_count raw bounds in
  if count = 0 || count > 4 * 1024 * 1024 then fallback ()
  else
    let words = Array.make count Felt.zero in
    let next = decode_hex Felt.pool raw words !(Felt.pool_n) bounds in
    if next < 0 then fallback () else begin
      Felt.pool_n := next;
      words
    end
