(* Stream ZIP members, then patch their local headers and write the directory. *)
open Errors

external crc_update : int -> bytes -> int -> int = "cvm_pie_crc_update"
external deflate : bytes -> int -> bytes -> int array -> int array -> int -> int
  = "cvm_pie_deflate_byte" "cvm_pie_deflate" [@@noalloc]

let block_size = 256 * 1024
let stride = block_size + block_size / 16 + 128
let blocks = 4

type compressor = {
  input : bytes;
  output : bytes;
  lengths : int array;
  settings : int array;
  mutable used : int;
}

let compressor level =
  {input = Bytes.create (blocks * block_size); output = Bytes.create (blocks * stride);
   lengths = Array.make blocks 0; settings = [|block_size; stride; level|]; used = 0}

let flush_blocks buffer oc crc =
  if buffer.used > 0 then begin
    let next = deflate buffer.input buffer.used buffer.output buffer.lengths buffer.settings !crc in
    if next < 0 then fail "Cairo PIE compression failed";
    crc := next;
    for i = 0 to (buffer.used - 1) / block_size do
      output oc buffer.output (i * stride) buffer.lengths.(i)
    done;
    buffer.used <- 0
  end

let feed buffer oc crc bytes length =
  let start = ref 0 in
  while !start < length do
    let take = min (length - !start) (Bytes.length buffer.input - buffer.used) in
    Bytes.blit bytes !start buffer.input buffer.used take;
    buffer.used <- buffer.used + take;
    start := !start + take;
    if buffer.used = Bytes.length buffer.input then flush_blocks buffer oc crc
  done

type profile = Fast | Rust_3_2 | Os_host_production
type archive

external open_pinned : string -> archive = "cvm_pinned_zip_open"
external start_member : archive -> string -> bool -> bool = "cvm_pinned_zip_start"
external append : archive -> bytes -> int -> bool = "cvm_pinned_zip_append"
external finish : archive -> bool = "cvm_pinned_zip_finish"
external close : archive -> unit = "cvm_pinned_zip_close"

let staged_write path write =
  let staged, channel =
    Filename.open_temp_file ~temp_dir:(Filename.dirname path) ".oxcairo-pie-" ".zip" in
  close_out channel;
  Fun.protect ~finally:(fun () -> if Sys.file_exists staged then Sys.remove staged) (fun () ->
    write staged;
    Sys.rename staged path)

let write_pinned ?(level_one=false) path members =
  staged_write path (fun staged ->
    let handle = open_pinned staged in
    Fun.protect ~finally:(fun () -> close handle) (fun () ->
      List.iter (fun (name, emit) ->
        if not (start_member handle name level_one) then fail "Cannot open Cairo PIE member %s" name;
        emit (fun bytes length ->
          if not (append handle bytes length) then fail "Cannot write Cairo PIE member %s" name)) members;
      if not (finish handle) then fail "Cannot finalize Cairo PIE"))

exception Classic_limit
exception Invalid_range

let write_classic ~method_id ~encode path members =
  if List.length members >= 0xffff then raise Classic_limit;
  Out_channel.with_open_bin path (fun oc ->
    let u16 n = output_byte oc n; output_byte oc (n lsr 8) in
    let u32 n = u16 n; u16 (n lsr 16) in
    let central = List.map (fun (name, write) ->
      if String.length name > 0xffff then fail "Cairo PIE member name is too long";
      let off = pos_out oc in
      if not (Pie_zip_limits.fits_field off) then raise Classic_limit;
      u32 0x04034b50; u16 20; u16 0; u16 method_id; u16 0; u16 33;
      u32 0; u32 0; u32 0; u16 (String.length name); u16 0; output_string oc name;
      let start = pos_out oc and crc = ref 0 and original = ref 0 in
      encode name (fun sink -> write (fun bytes len ->
        if len < 0 || len > Bytes.length bytes then fail "Invalid Cairo PIE member length";
        if len > Pie_zip_limits.max_field - !original then raise Classic_limit;
        original := !original + len;
        sink bytes len)) oc crc;
      let stop = pos_out oc in
      let packed = stop - start in
      if not (Pie_zip_limits.fits_field stop) then raise Classic_limit;
      seek_out oc (off + 14); u32 !crc; u32 packed; u32 !original; seek_out oc stop;
      name, !crc, packed, !original, off) members in
    let start = pos_out oc in
    List.iter (fun (name, crc, packed, original, off) ->
      u32 0x02014b50; u16 20; u16 20; u16 0; u16 method_id; u16 0; u16 33;
      u32 crc; u32 packed; u32 original; u16 (String.length name); u16 0; u16 0;
      u16 0; u16 0; u32 0; u32 off; output_string oc name) central;
    let size = pos_out oc - start in
    if not (Pie_zip_limits.fits_field size) then raise Classic_limit;
    u32 0x06054b50; u16 0; u16 0; u16 (List.length members);
    u16 (List.length members); u32 size; u32 start; u16 0;
    flush oc)


let write_fast ~level path members =
  if level < 0 || level > 9 then fail "Cairo PIE compression level must be between 0 and 9";
  let compressed = lazy (compressor level) in
  let encode _name write oc crc =
    if level = 0 then
      write (fun bytes len -> crc := crc_update !crc bytes len; output oc bytes 0 len)
    else begin
      write (feed (Lazy.force compressed) oc crc);
      flush_blocks (Lazy.force compressed) oc crc;
      output_string oc "\001\000\000\255\255"
    end in
  try write_classic ~method_id:(if level = 0 then 0 else 8) ~encode path members
  with Classic_limit -> fail "Cairo PIE zip exceeds the size limit"

external deflate_range : bytes -> int -> bool -> bytes -> int = "cvm_pie_deflate_range"

let write_production path members =
  let range_bytes = 32768 * 40 in
  (* The final range terminates the stream, including when it exactly fills the
     buffer. Keep one batch pending until another byte arrives or the member ends. *)
  let stride = range_bytes + range_bytes / 8 + 1024 in
  let memory = lazy (Bytes.create (blocks * range_bytes), Bytes.create (blocks * stride)) in
  let scratch = ref Bytes.empty in
  let encode name write oc crc =
    let block bytes n last =
      let capacity = n + n / 8 + 1024 in
      if Bytes.length !scratch < capacity then scratch := Bytes.create capacity;
      let size = deflate_range bytes n last !scratch in
      if size < 0 then raise Invalid_range;
      crc := crc_update !crc bytes n;
      output oc !scratch 0 size in
    if name <> "memory.bin" then begin
      let text = Buffer.create 256 in
      write (fun bytes len -> Buffer.add_subbytes text bytes 0 len);
      let bytes = Buffer.to_bytes text in
      block bytes (Bytes.length bytes) true
    end
    else begin
      let buffer, encoded = Lazy.force memory in
      let used = ref 0 and total = ref 0 and lengths = Array.make blocks 0 in
      let flush last =
        if !used = 0 then block buffer 0 true else begin
          let checksum = deflate buffer !used encoded lengths
              [|range_bytes; stride; 1; Bool.to_int last|] !crc in
          if checksum < 0 then raise Invalid_range;
          crc := checksum;
          for i = 0 to (!used - 1) / range_bytes do output oc encoded (i * stride) lengths.(i) done
        end;
        used := 0 in
      write (fun bytes len ->
        total := !total + len;
        if not (Pie_zip_limits.fits_production_memory !total) then raise Classic_limit;
        let offset = ref 0 in
        while !offset < len do
          if !used = Bytes.length buffer then flush false;
          let count = min (Bytes.length buffer - !used) (len - !offset) in
          Bytes.blit bytes !offset buffer !used count;
          used := !used + count;
          offset := !offset + count
        done);
      flush true
    end in
  try staged_write path (fun staged -> write_classic ~method_id:8 ~encode staged members)
  with Classic_limit | Invalid_range -> write_pinned ~level_one:true path members

let write ?(profile=Fast) ~level path members =
  match profile with
  | Fast -> write_fast ~level path members
  | Rust_3_2 -> write_pinned path members
  | Os_host_production -> write_production path members
