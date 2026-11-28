open Cairovm
open Worker_request

external clock : unit -> float = "cvm_worker_clock"
external lock : string -> Unix.file_descr = "cvm_worker_lock"
external rss : int -> int = "cvm_worker_rss"
external set_limits : int -> int -> int -> int -> int -> unit = "cvm_worker_limit"
external digest_fast : string -> Unix.file_descr option -> bytes -> bool = "cvm_worker_sha256"
external hash_while_writing : Unix.file_descr -> (unit -> unit) -> bytes -> bool
  = "cvm_worker_hash_during_write"

let emit json = Printf.printf "%s\n%!" (Yojson.Safe.to_string json)
let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let hash_string s =
  let digest = Bytes.create 32 in
  if digest_fast s None digest then hex (Bytes.unsafe_to_string digest) else hex (Sha256.digest s)

(* The portable backend streams full 64-byte blocks and pads only the tail. *)
let hash_fd fd =
  let dst = Bytes.create 32 in
  if digest_fast "" (Some fd) dst then hex (Bytes.unsafe_to_string dst)
  else begin
    let state = ref Sha256.iv and total = ref 0 and used = ref 0 in
    let b = Bytes.create 65536 in
    let consume len =
      for i=0 to len/64-1 do
        state := Sha256.compress !state (Array.init 16 (fun j ->
          Int32.to_int (Bytes.get_int32_be b (i*64+j*4)) land 0xffffffff))
      done in
    let rec read () =
      let n = Unix.read fd b !used (Bytes.length b - !used) in
      if n > 0 then begin
        total := !total + n;
        let len = !used + n in let full = len / 64 * 64 in
        consume full; used := len-full; Bytes.blit b full b 0 !used; read ()
      end in
    read ();
    let len = if !used < 56 then 64 else 128 in
    Bytes.fill b !used (len- !used) '\000'; Bytes.set b !used '\x80';
    Bytes.set_int64_be b (len-8) (Int64.mul 8L (Int64.of_int !total)); consume len;
    Array.iteri (fun i word -> Bytes.set_int32_be dst (4*i) (Int32.of_int word)) !state;
    hex (Bytes.unsafe_to_string dst)
  end

let with_fd fd f = Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)
let load path expected =
  let fd = Unix.openfile path [O_RDONLY; O_NONBLOCK; O_CLOEXEC] 0 in
  let ic = Unix.in_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let st = Unix.fstat fd in
    if st.st_kind <> S_REG || st.st_size > 128 lsl 20 then refuse 4 "program must be a regular file of at most 128 MiB";
    let source = try really_input_string ic st.st_size with End_of_file -> refuse 4 "program changed" in
    if In_channel.input_char ic <> None || hash_string source <> expected then refuse 4 "program digest mismatch";
    let program = Program.load_bytes ~parallel:false source in
    program,Program_image.prepare program,st)

let rec waitpid flags pid =
  try Unix.waitpid flags pid with Unix.Unix_error (EINTR, _, _) -> waitpid flags pid
let wait_child pid job deadline =
  let active = ref true in
  Fun.protect ~finally:(fun () ->
    if !active then begin
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error (ESRCH,_,_) -> ());
      ignore (waitpid [] pid)
    end) (fun () ->
    let rec poll () =
      if clock () >= deadline then refuse 22 "job deadline";
      if rss pid > job.limits.memory then refuse 21 "resident memory limit";
      match waitpid [WNOHANG] pid with
      | 0,_ -> Unix.sleepf 0.001; poll ()
      | _,status ->
          active := false;
          match status with
          | WEXITED 0 -> ()
          | WEXITED n -> refuse n (code_name n)
          | WSIGNALED n when n = Sys.sigxfsz -> refuse 23 "archive size limit"
          | WSIGNALED n when n = Sys.sigalrm -> refuse 22 "job deadline"
          | _ -> refuse 70 "worker terminated unexpectedly" in
    poll ())

let name output suffix = Filename.concat (Filename.dirname output) ("." ^ Filename.basename output ^ suffix)
let optional_stat p = try Some (Unix.lstat p) with Unix.Unix_error (ENOENT,_,_) -> None
let clean stage =
  let paths = Array.map (fun file ->
    let p = Filename.concat stage file in
    let temp = String.length file=23 && String.starts_with ~prefix:".oxcairo-pie-" file
               && String.ends_with ~suffix:".zip" file &&
               String.for_all (function '0'..'9'|'a'..'f'->true|_->false) (String.sub file 13 6) in
    if (not temp && file <> "out" && file <> "digest") || (Unix.lstat p).st_kind <> S_REG then
      refuse 27 "unexpected file in private stage";
    p) (Sys.readdir stage) in
  Array.iter Unix.unlink paths

let child job program image archive digest_path supervisor =
  let l = job.limits in
  set_limits l.memory l.files l.output_bytes (min l.wall 2_000_000_000) supervisor;
  let cfg = {Runner.layout="all_cairo"; trace=true; secure_run=true; allow_missing_builtins=false; entrypoint="main"} in
  let r = Os_hints.initialize ~image ~proof:false ~record_trace:true ~path:job.witness cfg program in
  Runner.run_until_end ~max_steps:l.steps r;
  Finalize.end_run r ~secure:true ~allow_missing:false;
  let profile,level = match job.profile with
    | Stored -> Pie_zip.Stored_headers,0 | Fast_one -> Pie_zip.Fast,1
    | Rust | Standard -> Pie_zip.Rust_3_2,0 in
  let write () =
    Pie.write ~profile ~compression_level:level ~merge_extra_segments:(job.profile=Standard)
      ~main:(Runner.entry_pc cfg program) ~secure:true r archive in
  let finish fd hash =
    if (Unix.fstat fd).st_size > l.output_bytes then refuse 23 "output limit";
    Unix.fsync fd; hash in
  let digest =
    match job.profile with
    | Stored ->
        with_fd (Unix.openfile archive [O_RDONLY;O_CREAT;O_EXCL;O_CLOEXEC] 0o600) (fun fd ->
          let dst = Bytes.create 32 in
          let hash = if hash_while_writing fd write dst then hex (Bytes.unsafe_to_string dst)
                     else hash_fd fd in
          finish fd hash)
    | _ ->
        write ();
        with_fd (Unix.openfile archive [O_RDONLY;O_CLOEXEC] 0) (fun fd -> finish fd (hash_fd fd)) in
  Out_channel.with_open_bin digest_path (fun oc -> output_string oc digest)

let run (program,image,program_stat) job =
  let deadline = clock () +. float job.limits.wall /. 1000. in
  let input = Unix.stat job.witness in
  if input.st_kind <> S_REG then refuse 5 "witness must be a regular file";
  Option.iter (fun (old:Unix.stats) ->
    let alias (s:Unix.stats) = s.st_dev=old.st_dev && s.st_ino=old.st_ino in
    if old.st_kind <> S_REG || alias input || alias program_stat then refuse 2 "invalid output or input alias")
    (optional_stat job.output);
  let lck = try lock (name job.output ".oxcairo.lock") with
    | Unix.Unix_error ((EAGAIN|EWOULDBLOCK),_,_) -> refuse 26 "output busy" in
  with_fd lck (fun _ ->
    let stage = name job.output ".oxcairo-worker-stage" in
    (try Unix.mkdir stage 0o700 with Unix.Unix_error (EEXIST,_,_) -> ());
    let st = Unix.lstat stage in
    if st.st_kind <> S_DIR || st.st_uid <> Unix.geteuid () || st.st_perm land 0o077 <> 0 then
      refuse 27 "unexpected staging directory";
    clean stage;
    Fun.protect ~finally:(fun () -> clean stage; Unix.rmdir stage) (fun () ->
      let archive=Filename.concat stage "out" and digest=Filename.concat stage "digest" in
      let supervisor=Unix.getpid () in
      match Unix.fork () with
      | 0 ->
          let code = try child job program image archive digest supervisor; 0 with e -> fst (classify e) in
          Unix._exit code
      | pid ->
          wait_child pid job deadline;
          let hash = In_channel.with_open_bin digest In_channel.input_all in
          let bytes = (Unix.stat archive).st_size in
          if clock () >= deadline then refuse 22 "publication deadline";
          Unix.rename archive job.output;
          with_fd (Unix.openfile (Filename.dirname job.output) [O_RDONLY;O_CLOEXEC] 0) Unix.fsync;
          `Assoc ["schema",`Int 1;"status",`String "ok";"bytes",`Int bytes;
                  "sha256",`String hash;"output",`String job.output]))

(* Bound each record independently, including a client that stops sending
   midway. Idle workers wait indefinitely for the first byte of a new job. *)
let serve ceiling prepared =
  let buf=Bytes.create 8192 and pos=ref 0 and len=ref 0 in
  let line=Buffer.create 1024 in
  let rec loop deadline =
    if !pos = !len then begin
      let timeout = match deadline with None -> -1. | Some t -> max 0. (t -. clock ()) in
      let ready,_,_ = Unix.select [Unix.stdin] [] [] timeout in
      if ready=[] then refuse 22 "incomplete request deadline";
      len := Unix.read Unix.stdin buf 0 (Bytes.length buf); pos := 0
    end;
    if !len=0 then begin if Buffer.length line<>0 then refuse 2 "unterminated request" end
    else begin
      let deadline = Option.value deadline ~default:(clock () +. float (min ceiling.wall 120000) /. 1000.) in
      let stop = match Bytes.index_from_opt buf !pos '\n' with Some n when n < !len -> n | _ -> !len in
      if Buffer.length line + stop - !pos > 65536 then refuse 2 "request exceeds 64 KiB";
      Buffer.add_subbytes line buf !pos (stop - !pos); pos := stop;
      if stop = !len then loop (Some deadline)
      else begin
        incr pos;
        (try emit (run prepared (request ceiling (Buffer.contents line)))
         with e -> let code,msg = classify e in emit (refusal code msg));
        Buffer.clear line; loop None
      end
    end in
  loop None

let main () =
  try
    if Array.length Sys.argv <> 5 || Sys.argv.(3) <> "--sha256" then
      refuse 2 "usage: oxcairo-os-worker pie-v1 PROGRAM --sha256 SHA256";
    let expected=Sys.argv.(4) in
    if String.length expected<>64 || not (String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) expected)
    then refuse 2 "expected lowercase SHA-256 operator pin";
    let ceiling = match Sys.getenv_opt "OXCAIRO_HOST_LIMITS" with None -> defaults
      | Some s -> limits defaults (parse s) in
    Unix.putenv "OXCAIRO_HOST_DETERMINISTIC" "1";
    Os_hints.configure_batch_gc ();
    (* OxCaml reserves a Linux address range for every potential domain.
       Apply a bounded nursery configuration once, before loading the pin. *)
    (if Sys.file_exists "/proc/self/statm" && Sys.getenv_opt "OCAMLRUNPARAM" = None &&
        Sys.getenv_opt "CAMLRUNPARAM" = None then begin
       let domains = max 1 (min 4 (ceiling.memory / (128 lsl 20))) in
       let words = min (4 lsl 20) (ceiling.memory / 256) in
       Unix.putenv "OCAMLRUNPARAM" (Printf.sprintf "d=%d,s=%d,o=250" domains words);
       Unix.execv Sys.executable_name Sys.argv
     end);
    let prepared = load Sys.argv.(2) expected in
    Gc.full_major ();
    emit (`Assoc ["schema",`Int 1;"status",`String "ready";"program_sha256",`String expected]);
    serve ceiling prepared
  with e -> let code,msg = classify e in emit (refusal code msg); exit code
