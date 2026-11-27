open Errors

type seg_info = { index : int; size : int }

type t = {
  data : Z.t array;
  builtins : string list;
  main : int;
  program_segment : seg_info;
  execution_segment : seg_info;
  ret_fp_segment : seg_info;
  ret_pc_segment : seg_info;
  builtin_segments : (string * seg_info) list;
  extra_segments : seg_info list;
  memory : Bytes.t;
  n_steps : int;
  builtin_instance_counter : (string * int) list;
  additional : (string * Yojson.Safe.t) list;
}

let cell_bytes = 40
let n_cells t = Bytes.length t.memory / cell_bytes

(* ---- zip container ---- *)

external inflate_raw : string -> int -> int -> int -> Bytes.t = "cvm_inflate_raw"
external crc32_bytes : Bytes.t -> int = "cvm_crc32_bytes"

let u16 s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)
let u32 s o = u16 s o lor (u16 s (o + 2) lsl 16)
let u64 s o = u32 s o lor (u32 s (o + 4) lsl 32) (* sizes and offsets stay far below 2^62 *)

type member = { name : string; meth : int; crc : int; csize : int; usize : int; local : int }

let bad fmt = Printf.ksprintf (fun m -> fail "Invalid Cairo PIE zip: %s" m) fmt

let central_directory s =
  let n = String.length s in
  let rec find_eocd o =
    if o < 0 || o < n - 22 - 0xffff then bad "no end of central directory"
    else if u32 s o = 0x06054b50 then o
    else find_eocd (o - 1)
  in
  let eocd = find_eocd (n - 22) in
  let entries = u16 s (eocd + 10) and cd = u32 s (eocd + 16) in
  let entries, cd =
    if (entries = 0xffff || cd = 0xffffffff) && eocd >= 20 && u32 s (eocd - 20) = 0x07064b50 then begin
      let z = u64 s (eocd - 12) in
      if z + 56 > n || u32 s z <> 0x06064b50 then bad "bad zip64 end of central directory";
      (u64 s (z + 32), u64 s (z + 48))
    end
    else (entries, cd)
  in
  let rec loop o k acc =
    if k = entries then List.rev acc
    else begin
      if o + 46 > n || u32 s o <> 0x02014b50 then bad "bad central directory entry";
      let nlen = u16 s (o + 28) and elen = u16 s (o + 30) and clen = u16 s (o + 32) in
      let name = String.sub s (o + 46) nlen in
      let usize = ref (u32 s (o + 24)) and csize = ref (u32 s (o + 20)) and local = ref (u32 s (o + 42)) in
      (* zip64 extended information: present fields follow in this order *)
      let e = ref (o + 46 + nlen) and e_end = o + 46 + nlen + elen in
      while !e + 4 <= e_end do
        let id = u16 s !e and len = u16 s (!e + 2) in
        if id = 1 then begin
          let p = ref (!e + 4) in
          let take r = if !r = 0xffffffff then (r := u64 s !p; p := !p + 8) in
          take usize; take csize; take local
        end;
        e := !e + 4 + len
      done;
      let m = { name; meth = u16 s (o + 10); crc = u32 s (o + 16); csize = !csize; usize = !usize; local = !local } in
      loop (e_end + clen) (k + 1) (m :: acc)
    end
  in
  loop cd 0 []

let member_bytes s m =
  let o = m.local in
  if o + 30 > String.length s || u32 s o <> 0x04034b50 then bad "bad local header for %s" m.name;
  let start = o + 30 + u16 s (o + 26) + u16 s (o + 28) in
  if start + m.csize > String.length s then bad "%s is truncated" m.name;
  let b =
    match m.meth with
    | 0 -> if m.csize <> m.usize then bad "%s: stored sizes differ" m.name else Bytes.of_string (String.sub s start m.csize)
    | 8 -> inflate_raw s start m.csize m.usize
    | k -> bad "%s: unsupported compression method %d" m.name k
  in
  if crc32_bytes b <> m.crc then bad "%s: CRC mismatch" m.name;
  b

(* ---- JSON ---- *)

module U = Yojson.Safe.Util

let z_of_json = function
  | `Int i -> Z.of_int i
  | `Intlit s -> Z.of_string s
  | `String s -> Z.of_string s
  | `Float f when Float.is_integer f -> Z.of_float f
  | j -> fail "Invalid Cairo PIE: expected an integer, found %s" (Yojson.Safe.to_string j)

let int_of_json j =
  let z = z_of_json j in
  if Z.sign z < 0 || not (Z.fits_int z) then fail "Invalid Cairo PIE: integer out of range: %s" (Z.to_string z);
  Z.to_int z

let seg_info j = { index = int_of_json (U.member "index" j); size = int_of_json (U.member "size" j) }

let assoc what = function
  | `Assoc l -> l
  | _ -> fail "Invalid Cairo PIE: %s is not an object" what

let strip_suffix k =
  let s = "_builtin" in
  let n = String.length k and m = String.length s in
  if n > m && String.sub k (n - m) m = s then String.sub k 0 (n - m)
  else fail "Invalid Cairo PIE: unknown builtin %s" k

let builtin_name k =
  match Builtin.bkind_of_name k with Some _ -> k | None -> fail "Invalid Cairo PIE: unknown builtin %s" k

let read path =
  let s = In_channel.with_open_bin path In_channel.input_all in
  let members = central_directory s in
  let get name =
    match List.find_opt (fun m -> m.name = name) members with
    | Some m -> member_bytes s m
    | None -> fail "Invalid Cairo PIE: missing %s" name
  in
  let json name = Yojson.Safe.from_string (Bytes.unsafe_to_string (get name)) in
  (match List.find_opt (fun m -> m.name = "version.json") members with
   | None -> ()
   | Some m -> (
       match U.member "cairo_pie" (Yojson.Safe.from_string (Bytes.unsafe_to_string (member_bytes s m))) with
       | `String "1.0" | `String "1.1" -> ()
       | _ -> fail "Invalid Cairo PIE: unsupported version"));
  let meta = json "metadata.json" in
  let prog = U.member "program" meta in
  if not (Z.equal (z_of_json (U.member "prime" prog)) Felt.p) then fail "Invalid Cairo PIE: unexpected field prime";
  let memory = get "memory.bin" in
  if Bytes.length memory mod cell_bytes <> 0 then fail "Invalid Cairo PIE: memory.bin length is not a multiple of 40";
  let resources = json "execution_resources.json" in
  {
    data = Array.of_list (List.map z_of_json (U.to_list (U.member "data" prog)));
    builtins = List.map (fun j -> builtin_name (U.to_string j)) (U.to_list (U.member "builtins" prog));
    main = int_of_json (U.member "main" prog);
    program_segment = seg_info (U.member "program_segment" meta);
    execution_segment = seg_info (U.member "execution_segment" meta);
    ret_fp_segment = seg_info (U.member "ret_fp_segment" meta);
    ret_pc_segment = seg_info (U.member "ret_pc_segment" meta);
    builtin_segments =
      List.map (fun (k, v) -> (builtin_name k, seg_info v)) (assoc "builtin_segments" (U.member "builtin_segments" meta));
    extra_segments = List.map seg_info (U.to_list (U.member "extra_segments" meta));
    memory;
    n_steps = int_of_json (U.member "n_steps" resources);
    builtin_instance_counter =
      List.map
        (fun (k, v) -> (builtin_name (strip_suffix k), int_of_json v))
        (assoc "builtin_instance_counter" (U.member "builtin_instance_counter" resources));
    additional = List.map (fun (k, v) -> (builtin_name (strip_suffix k), v)) (assoc "additional_data" (json "additional_data.json"));
  }
