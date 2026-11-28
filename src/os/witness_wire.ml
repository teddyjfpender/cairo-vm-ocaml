(* OXW1 frames a definite-length CBOR witness. Only JSON-model values can
   enter the hint processor. In particular no wire integer is an offset into
   another input and no OCaml object or pointer is deserialized. *)
let magic = "OXW1"
let max_bytes = 256 lsl 20
let max_nodes = 4 lsl 20
let max_depth = 256
let invalid message = raise (Yojson.Json_error ("Invalid OXW1 witness: " ^ message))

type location = Root | Os_input | Classes | Legacy_classes | Class | Legacy_class | Class_body | Words | Other

let field parent key = match parent, key with
  | Root, "os_input" -> Os_input
  | Os_input, "compiled_classes" -> Classes
  | Os_input, "deprecated_compiled_classes" -> Legacy_classes
  | Legacy_classes, _ -> Legacy_class
  | Classes, _ -> Class
  | (Class | Class_body), "bytecode" -> Words
  | _ -> Other

type class_entry = { kind : location; bytes : string; value : Yojson.Safe.t; nodes : int }
type cache = { entries : class_entry option array; mutable next : int }
let resident_cache = Domain.DLS.new_key (fun () -> { entries=Array.make 12 None; next=0 })
external matches_at : string -> int -> string -> bool = "cvm_json_matches_at" [@@noalloc]

let decode_payload ?cache payload : Yojson.Safe.t =

  let size = String.length payload in
  if size > max_bytes then invalid "size limit";
  let pos = ref 0 and nodes = ref 0 and limit = ref size in
  let take n =
    if n < 0 || n > !limit - !pos then invalid "truncated item";
    let start = !pos in pos := start + n; start in
  let byte () = Char.code payload.[take 1] in
  let argument = function
    | n when n < 24 -> Int64.of_int n
    | 24 -> Int64.of_int (byte ())
    | 25 -> Int64.of_int (String.get_uint16_be payload (take 2))
    | 26 -> Int64.logand 0xffff_ffffL (Int64.of_int32 (String.get_int32_be payload (take 4)))
    | 27 -> String.get_int64_be payload (take 8)
    | _ -> invalid "indefinite or reserved argument" in
  let length info =
    let v = argument info in
    if Int64.unsigned_compare v (Int64.of_int (!limit - !pos)) > 0 then invalid "length exceeds input";
    Int64.to_int v in
  let text info =
    let n = length info in
    let s = String.sub payload (take n) n in
    if not (String.is_valid_utf_8 s) then invalid "invalid UTF-8";
    s in
  let integer negative bits =
    if Int64.unsigned_compare bits (Int64.of_int max_int) <= 0 then
      let n = Int64.to_int bits in `Int (if negative then -1-n else n)
    else
      let n = Z.of_int64_unsigned bits in
      `Intlit (Z.to_string (if negative then Z.lognot n else n)) in
  let rec value depth location =
    incr nodes;
    if !nodes > max_nodes || depth > max_depth then invalid "structure limit";
    let head = byte () in
    let info = head land 31 in
    match head lsr 5 with
    | 0 -> integer false (argument info)
    | 1 -> integer true (argument info)
    | 2 when location = Words ->
        let n = length info in
        let raw = String.sub payload (take n) n in
        let words = Witness_words.count raw in
        if words < 0 || words > max_nodes - !nodes then invalid "invalid packed word vector";
        nodes := !nodes + words;
        `Variant ("OXW1.words", Some (`String raw))
    | 3 -> `String (text info)
    | 4 ->
        let n = length info in
        if n > max_nodes - !nodes then invalid "array item limit";
        `List (List.init n (fun _ -> value (depth+1) Other))
    | 5 ->
        let n = length info in
        if n > (!limit - !pos) / 2 || n > (max_nodes - !nodes) / 2 then invalid "map item limit";
        let keys = Hashtbl.create ~random:true (min n 32) in
        `Assoc (List.init n (fun _ ->
            incr nodes;
            let key_head = byte () in
            if key_head lsr 5 <> 3 then invalid "non-text map key";
            let key = text (key_head land 31) in
            if Hashtbl.mem keys key then invalid "duplicate map key";
            Hashtbl.add keys key ();
            let item = value (depth+1) (field location key) in key, item))
    | 6 when (location = Class || location = Legacy_class) ->
        if argument info <> 24L then invalid "unsupported class tag";
        let h = byte () in
        if h lsr 5 <> 2 then invalid "expected framed class bytes";
        let n = length (h land 31) in
        let start = !pos in
        let cached = Option.bind cache (fun c ->
            Array.find_map (function
                | Some e when e.kind = location && String.length e.bytes = n &&
                              matches_at payload start e.bytes -> Some e
                | _ -> None) c.entries) in
        (match cached with
         | Some e ->
             if e.nodes > max_nodes - !nodes then invalid "class item limit";
             pos := start + n; nodes := !nodes + e.nodes; e.value
         | None ->
             let outer_limit = !limit and before = !nodes in
             limit := start + n;
             let data = value (depth+1) (if location = Class then Class_body else Other) in
             if !pos <> !limit then invalid "class frame length";
             limit := outer_limit;
             (match data with `Assoc _ -> () | _ -> invalid "expected class map");
             (match cache with
              | Some c when n <= 2_097_152 && !nodes - before <= 150_000 ->
                  c.entries.(c.next) <- Some {kind=location; bytes=String.sub payload start n;
                                              value=data; nodes= !nodes-before};
                  c.next <- (c.next+1) mod Array.length c.entries
              | _ -> ());
             data)
    | 6 ->

        let tag = argument info in
        if tag <> 2L && tag <> 3L then invalid "unsupported tag";
        let h = byte () in
        if h lsr 5 <> 2 then invalid "expected bignum bytes";
        let n = length (h land 31) in
        if n > 32 then invalid "bignum exceeds 256 bits";
        let first = take n in
        let magnitude = ref Z.zero in
        for i = first to first+n-1 do
          magnitude := Z.logor (Z.shift_left !magnitude 8) (Z.of_int (Char.code payload.[i]))
        done;
        let z = if tag = 2L then !magnitude else Z.lognot !magnitude in
        if Z.fits_int z then `Int (Z.to_int z) else `Intlit (Z.to_string z)
    | 7 -> (match info with
        | 20 -> `Bool false | 21 -> `Bool true | 22 -> `Null
        | 26 | 27 ->
            let f = if info=26 then Int32.float_of_bits (String.get_int32_be payload (take 4))
              else Int64.float_of_bits (String.get_int64_be payload (take 8)) in
            if not (Float.is_finite f) then invalid "non-finite float";
            `Float f
        | _ -> invalid "unsupported simple value")
    | _ -> invalid "unsupported byte string" in
  let result = value 0 Root in
  if !pos <> size then invalid "trailing items";
  match result with `Assoc _ -> result | _ -> invalid "expected witness map"

let decode payload = decode_payload payload

type input = Json of string | Binary of Yojson.Safe.t

let read_file ?(resident=false) path =
  In_channel.with_open_bin path (fun ch ->
      match input_char ch with
      | exception End_of_file -> Json ""
      | 'O' ->
          (try
             if really_input_string ch 3 <> "XW1" then invalid "unknown version";
             let size = Int64.logand 0xffff_ffffL
                 (Int64.of_int32 (String.get_int32_be (really_input_string ch 4) 0)) in
             if size > Int64.of_int max_bytes then invalid "size limit";
             let n = Int64.to_int size in
             (* Check a regular file before allocating from an untrusted header. *)
             let fd = Unix.descr_of_in_channel ch in
             let stat = Unix.LargeFile.fstat fd in
             if stat.st_kind = Unix.S_REG && stat.st_size <> Int64.add size 8L then invalid "frame length";
             let payload = really_input_string ch n in
             (match input_char ch with exception End_of_file -> () | _ -> invalid "trailing bytes");
             let cache = if resident then Some (Domain.DLS.get resident_cache) else None in
             Binary (decode_payload ?cache payload)
           with End_of_file -> invalid "truncated frame")
      | first ->
          let rewind = try seek_in ch 0; true with Sys_error _ -> false in
          Json (if rewind then In_channel.input_all ch
                else String.make 1 first ^ In_channel.input_all ch))

let write channel (document : Yojson.Safe.t) =
  let out = ref (Buffer.create 65536) and nodes = ref 0 in
  let reserve n =
    if n > max_bytes - Buffer.length !out then invalid "size limit" in
  let argument kind bits =
    let header extra = Buffer.add_uint8 !out (kind lsl 5 lor extra) in
    let below n = Int64.unsigned_compare bits n < 0 in
    if below 24L then (reserve 1; header (Int64.to_int bits))
    else if below 256L then (reserve 2; header 24; Buffer.add_uint8 !out (Int64.to_int bits))
    else if below 65536L then (reserve 3; header 25; Buffer.add_uint16_be !out (Int64.to_int bits))
    else if below 0x1_0000_0000L then
      (reserve 5; header 26; Buffer.add_int32_be !out (Int64.to_int32 bits))
    else (reserve 9; header 27; Buffer.add_int64_be !out bits) in
  let text s =
    if not (String.is_valid_utf_8 s) then invalid "invalid UTF-8";
    let n = String.length s in
    argument 3 (Int64.of_int n); reserve n; Buffer.add_string !out s in
  let count () =
    incr nodes; if !nodes > max_nodes then invalid "structure limit" in
  let rec item depth location value =
    count (); if depth > max_depth then invalid "structure limit";
    if location = Class || location = Legacy_class then begin
      (match value with `Assoc _ -> () | _ -> invalid "expected class map");
      let parent = !out in
      out := Buffer.create 4096;
      item (depth+1) (if location = Class then Class_body else Other) value;
      let body = !out in
      out := parent;
      let n = Buffer.length body in
      argument 6 24L; argument 2 (Int64.of_int n); reserve n; Buffer.add_buffer !out body
    end else match value with
    | `Null -> reserve 1; Buffer.add_uint8 !out 0xf6
    | `Bool b -> reserve 1; Buffer.add_uint8 !out (if b then 0xf5 else 0xf4)
    | `Int n ->
        if n < 0 then argument 1 (Int64.of_int (lnot n)) else argument 0 (Int64.of_int n)
    | `Intlit s ->
        if String.length s > 79 then invalid "integer exceeds 256 bits";
        let z = try Z.of_string s with Invalid_argument _ -> invalid "invalid integer" in
        let negative = Z.sign z < 0 in
        let magnitude = if negative then Z.lognot z else z in
        let bits = Z.numbits magnitude in
        if bits <= 64 then argument (if negative then 1 else 0) (Z.to_int64_unsigned magnitude)
        else begin
          if bits > 256 then invalid "integer exceeds 256 bits";
          argument 6 (if negative then 3L else 2L);
          let bytes = (bits+7)/8 in
          argument 2 (Int64.of_int bytes); reserve bytes;
          for i = bytes-1 downto 0 do Buffer.add_uint8 !out (Z.to_int (Z.extract magnitude (i*8) 8)) done
        end
    | `Float f ->
        if not (Float.is_finite f) then invalid "non-finite float";
        reserve 9; Buffer.add_uint8 !out 0xfb; Buffer.add_int64_be !out (Int64.bits_of_float f)
    | `String s -> text s
    | `Variant ("OXW1.words", Some (`String raw)) when location = Words ->
        let words = Witness_words.count raw in
        if words < 0 || words > max_nodes - !nodes then invalid "invalid packed word vector";
        nodes := !nodes + words;
        let bytes = String.length raw in
        argument 2 (Int64.of_int bytes); reserve bytes; Buffer.add_string !out raw
    | `List xs when location = Words ->
        let n = List.length xs in
        if n > max_nodes - !nodes then invalid "word count exceeds limit";
        nodes := !nodes + n;
        let raw = Witness_words.encode xs in
        let bytes = String.length raw in
        argument 2 (Int64.of_int bytes); reserve bytes; Buffer.add_string !out raw
    | `List xs ->
        argument 4 (Int64.of_int (List.length xs));
        List.iter (item (depth+1) Other) xs
    | `Assoc fields ->
        let n = List.length fields in
        argument 5 (Int64.of_int n);
        let keys = Hashtbl.create ~random:true (min n 32) in
        List.iter (fun (key, data) ->
            count ();
            if Hashtbl.mem keys key then invalid "duplicate map key";
            Hashtbl.add keys key (); text key; item (depth+1) (field location key) data) fields
    | `Tuple _ | `Variant _ -> invalid "unsupported JSON value" in
  (match document with `Assoc _ -> () | _ -> invalid "expected witness map");
  item 0 Root document;
  output_string channel magic;
  output_binary_int channel (Buffer.length !out);
  Buffer.output_buffer channel !out
