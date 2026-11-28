(* Emit ZIP32 headers after streaming each member. The compressed path uses
   at most four independent 256 KiB DEFLATE blocks at a time. *)
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

type profile = Fast | Stored_headers | Rust_3_2
type archive

external open_pinned : string -> archive = "cvm_pinned_zip_open"
external start_member : archive -> string -> bool = "cvm_pinned_zip_start"
external append : archive -> bytes -> int -> bool = "cvm_pinned_zip_append"
external finish : archive -> bool = "cvm_pinned_zip_finish"
external close : archive -> unit = "cvm_pinned_zip_close"

let write_pinned path members =
  let staged, channel =
    Filename.open_temp_file ~temp_dir:(Filename.dirname path) ".oxcairo-pie-" ".zip" in
  close_out channel;
  Fun.protect ~finally:(fun () -> if Sys.file_exists staged then Sys.remove staged) (fun () ->
    let handle = open_pinned staged in
    Fun.protect ~finally:(fun () -> close handle) (fun () ->
      List.iter (fun (name, emit) ->
        if not (start_member handle name) then fail "Cannot open Cairo PIE member %s" name;
        emit (fun bytes length ->
          if not (append handle bytes length) then fail "Cannot write Cairo PIE member %s" name)) members;
      if not (finish handle) then fail "Cannot finalize Cairo PIE");
    Sys.rename staged path)

let write_fast ~known ~level path members =
  if level < 0 || level > 9 then fail "Cairo PIE compression level must be between 0 and 9";
  let method_id = if level = 0 then 0 else 8 in
  let compressed = lazy (compressor level) in
  Out_channel.with_open_bin path (fun oc ->
    let u16 n = output_byte oc n; output_byte oc (n lsr 8) in
    let u32 n = u16 n; u16 (n lsr 16) in
    let central = List.map (fun (name, write) ->
      let off = pos_out oc in
      if off > 0xfffffffe then fail "Cairo PIE zip exceeds the size limit";
      let initial_crc, initial_size =
        if known then begin
          let crc = ref 0 and size = ref 0 in
          write (fun bytes len ->
            if len < 0 || len > Bytes.length bytes || len > 0xfffffffe - !size then
              fail "Cairo PIE zip member exceeds the size limit";
            size := !size + len;
            crc := crc_update !crc bytes len);
          !crc, !size
        end else 0,0 in
      u32 0x04034b50; u16 20; u16 0; u16 method_id; u16 0; u16 33;
      u32 initial_crc; u32 initial_size; u32 initial_size;
      u16 (String.length name); u16 0; output_string oc name;
      let start = pos_out oc and crc = ref initial_crc and original = ref 0 in
      let emit bytes len =
        if len < 0 || len > Bytes.length bytes || len > 0xfffffffe - !original then
          fail "Cairo PIE zip member exceeds the size limit";
        original := !original + len;
        if level = 0 then begin
          if not known then crc := crc_update !crc bytes len;
          output oc bytes 0 len
        end else feed (Lazy.force compressed) oc crc bytes len in
      write emit;
      if level <> 0 then begin
        flush_blocks (Lazy.force compressed) oc crc;
        output_string oc "\001\000\000\255\255"
      end;
      let stop = pos_out oc in
      let packed = stop - start in
      if stop > 0xfffffffe then fail "Cairo PIE zip exceeds the size limit";
      if known then begin
        if packed <> initial_size then fail "Cairo PIE member size changed between passes"
      end else begin
        seek_out oc (off + 14); u32 !crc; u32 packed; u32 !original; seek_out oc stop
      end;
      name, !crc, packed, !original, off) members in
    let start = pos_out oc in
    List.iter (fun (name, crc, packed, original, off) ->
      u32 0x02014b50; u16 20; u16 20; u16 0; u16 method_id; u16 0; u16 33;
      u32 crc; u32 packed; u32 original; u16 (String.length name); u16 0; u16 0;
      u16 0; u16 0; u32 0; u32 off; output_string oc name) central;
    let size = pos_out oc - start in
    u32 0x06054b50; u16 0; u16 0; u16 (List.length members);
    u16 (List.length members); u32 size; u32 start; u16 0)


let write ?(profile=Fast) ~level path members =
  match profile with
  | Fast -> write_fast ~known:false ~level path members
  | Stored_headers -> write_fast ~known:true ~level:0 path members
  | Rust_3_2 -> write_pinned path members
