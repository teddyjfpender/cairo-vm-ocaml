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

module BA = Bigarray.Array1
type archive = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) BA.t

external stored : archive -> int -> int -> bytes = "cvm_pie_stored"
external inflate_raw : archive -> int -> int -> int -> Bytes.t = "cvm_inflate_raw"
external crc32_bytes : Bytes.t -> int = "cvm_crc32_bytes"

let u16 s o = Char.code (BA.get s o) lor (Char.code (BA.get s (o + 1)) lsl 8)
let u32 s o = u16 s o lor (u16 s (o + 2) lsl 16)
let u64 s o =
  let hi = u32 s (o + 4) in
  if hi > max_int lsr 32 then fail "Cairo PIE zip64 size exceeds native integer range";
  u32 s o lor (hi lsl 32)

type member = { name : string; meth : int; crc : int; csize : int; usize : int; local : int }

let bad fmt = Printf.ksprintf (fun m -> fail "Invalid Cairo PIE zip: %s" m) fmt

let fits ~limit offset size = offset >= 0 && offset <= limit && size <= limit - offset

let central_directory s =
  let n = BA.dim s in
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
      if not (fits ~limit:n z 56) || u32 s z <> 0x06064b50 then bad "bad zip64 end of central directory";
      (u64 s (z + 32), u64 s (z + 48))
    end
    else (entries, cd)
  in
  let rec loop o k acc =
    if k = entries then List.rev acc
    else begin
      if not (fits ~limit:eocd o 46) || u32 s o <> 0x02014b50 then bad "bad central directory entry";
      let nlen = u16 s (o + 28) and elen = u16 s (o + 30) and clen = u16 s (o + 32) in
      if not (fits ~limit:eocd (o + 46) (nlen + elen + clen)) then bad "truncated central directory entry";
      let name = String.init nlen (fun i -> BA.get s (o + 46 + i)) in
      let usize = ref (u32 s (o + 24)) and csize = ref (u32 s (o + 20)) and local = ref (u32 s (o + 42)) in
      (* zip64 extended information: present fields follow in this order *)
      let e = ref (o + 46 + nlen) and e_end = o + 46 + nlen + elen in
      while !e + 4 <= e_end do
        let id = u16 s !e and len = u16 s (!e + 2) in
        if len > e_end - !e - 4 then bad "truncated extra field";
        if id = 1 then begin
          let p = ref (!e + 4) in
          let take r =
            if !r = 0xffffffff then begin
              if not (fits ~limit:(!e + 4 + len) !p 8) then bad "truncated zip64 size";
              r := u64 s !p; p := !p + 8
            end
          in
          take usize; take csize; take local
        end;
        e := !e + 4 + len
      done;
      let m = { name; meth = u16 s (o + 10); crc = u32 s (o + 16); csize = !csize; usize = !usize; local = !local } in
      loop (e_end + clen) (k + 1) (m :: acc)
    end
  in
  loop cd 0 []

let member_start s m =
  let o = m.local in
  if not (fits ~limit:(BA.dim s) o 30) || u32 s o <> 0x04034b50 then bad "bad local header for %s" m.name;
  let start = o + 30 + u16 s (o + 26) + u16 s (o + 28) in
  if not (fits ~limit:(BA.dim s) start m.csize) then bad "%s is truncated" m.name;
  start

let member_bytes s m =
  let start = member_start s m in
  let b =
    match m.meth with
    | 0 -> if m.csize <> m.usize then bad "%s: stored sizes differ" m.name else stored s start m.csize
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

type memory_source = { archive : archive; member : member }
external iter_member : archive -> int array -> (bytes -> unit) -> int = "cvm_pie_iter_member"

let iter_memory ?(parallel=true) source consume =
  let s = source.archive and m = source.member in
  let offset = member_start s m in
  let crc = iter_member s [|offset;m.csize;m.usize;m.meth;Bool.to_int parallel|] consume in
  if crc <> m.crc then bad "%s: CRC mismatch" m.name

let read_deferred path =
  let s = In_channel.with_open_bin path (fun channel ->
      let length = in_channel_length channel in
      if length < 22 then bad "no end of central directory";
      Unix.map_file (Unix.descr_of_in_channel channel) Bigarray.char Bigarray.c_layout false [|length|]
      |> Bigarray.array1_of_genarray) in
  let members = central_directory s in
  let find name =
    match List.find_opt (fun m -> m.name = name) members with
    | Some m -> m
    | None -> fail "Invalid Cairo PIE: missing %s" name
  in
  let json name = Yojson.Safe.from_string (Bytes.unsafe_to_string (member_bytes s (find name))) in
  (match List.find_opt (fun m -> m.name = "version.json") members with
   | None -> ()
   | Some m -> (
       match U.member "cairo_pie" (Yojson.Safe.from_string (Bytes.unsafe_to_string (member_bytes s m))) with
       | `String "1.0" | `String "1.1" -> ()
       | _ -> fail "Invalid Cairo PIE: unsupported version"));
  let meta = json "metadata.json" in
  let prog = U.member "program" meta in
  if not (Z.equal (z_of_json (U.member "prime" prog)) Felt.p) then fail "Invalid Cairo PIE: unexpected field prime";
  let member = find "memory.bin" in
  if member.usize mod cell_bytes <> 0 then fail "Invalid Cairo PIE: memory.bin length is not a multiple of 40";
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
    memory = Bytes.empty;
    n_steps = int_of_json (U.member "n_steps" resources);
    builtin_instance_counter =
      List.map
        (fun (k, v) -> (builtin_name (strip_suffix k), int_of_json v))
        (assoc "builtin_instance_counter" (U.member "builtin_instance_counter" resources));
    additional = List.map (fun (k, v) -> (builtin_name (strip_suffix k), v)) (assoc "additional_data" (json "additional_data.json"));
  }, {archive=s; member}

let read path =
  let pie,source = read_deferred path in
  {pie with memory=member_bytes source.archive source.member}
