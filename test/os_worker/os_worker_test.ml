open Cairovm
module J = Yojson.Safe
let field key value = J.Util.member key value |> J.Util.to_string
let hex raw = String.concat "" (List.init (String.length raw) (fun i -> Printf.sprintf "%02x" (Char.code raw.[i])))
let sha path = In_channel.with_open_bin path (fun ic -> hex (Sha256.digest (In_channel.input_all ic)))
let () =
  let worker=Unix.realpath Sys.argv.(1) and gz=Unix.realpath Sys.argv.(2)
  and genesis=Unix.realpath Sys.argv.(3) in
  let absolute name=Filename.concat (Sys.getcwd ()) name in
  (* Match the pinned Apollo genesis recipe used by the reference corpus. *)
  let set k v j = `Assoc ((k,v) :: List.remove_assoc k (J.Util.to_assoc j)) in
  let doc=J.from_file genesis in
  let os=J.Util.member "os_input" doc in
  let block=List.hd (J.Util.to_list (J.Util.member "os_block_inputs" os)) in
  let info=set "starknet_version" (`String "0.14.4") (J.Util.member "block_info" block) in
  let hash="0x6ed5aea93a2b1b36411dde07afd4b1542fc012d41753e5eda1ebca441dc151" in
  let block=block |> set "block_info" info |> set "new_block_hash" (`String hash) |> set "starknet_version_override" `Null in
  let witness=absolute "input.json" in
  J.to_file witness (doc |> set "os_input" (set "os_block_inputs" (`List [block]) os)
    |> set "os_hints_config" (set "full_output" (`Bool true) (J.Util.member "os_hints_config" doc)));
  let program=absolute "compiled-os.json" and output=absolute "out.zip" in
  let fd=Unix.openfile program [O_WRONLY; O_CREAT; O_TRUNC] 0o600 in
  let _,status = Unix.waitpid [] (Unix.create_process "gzip" [|"gzip"; "-dc"; gz|] Unix.stdin fd Unix.stderr) in
  Unix.close fd; assert (status=Unix.WEXITED 0);
  let pin=sha program in
  (* Stage the installed sibling layout, then exercise the public entry point
     with Python and all other executables removed from PATH. *)
  let bin=absolute "installed bin" in
  (try Unix.mkdir bin 0o700 with Unix.Unix_error (EEXIST,_,_) -> ());
  let install name source =
    let path=Filename.concat bin name in
    (try Unix.unlink path with Unix.Unix_error (ENOENT,_,_) -> ());
    Unix.symlink source path; path in
  ignore (install "oxcairo-os-worker" worker);
  let host=install "oxcairo-os-host" (Unix.realpath Sys.argv.(4)) in
  let serve pin f =
    let env = Unix.environment () |> Array.to_list |>
      List.filter (fun s -> not (String.starts_with ~prefix:"PATH=" s)) in
    let ic,oc,ec=Unix.open_process_args_full host [|host;"worker-v1";program;"--sha256";pin|]
        (Array.of_list ("PATH=/unavailable"::env)) in
    let receive ()=J.from_string (input_line ic) in
    let send line=output_string oc line; output_char oc '\n'; flush oc; receive () in
    let result=f (receive ()) send in
    close_out_noerr oc; let status=Unix.close_process_full (ic,oc,ec) in result,status in
  let _,bad=serve (String.make 64 '0') (fun ready _ -> assert (field "code" ready="program_mismatch")) in
  assert (bad=Unix.WEXITED 4);
  let _,status=serve pin (fun ready send ->
    assert (field "status" ready="ready" && field "program_sha256" ready=pin);
    let job ?(input=witness) ?(out=output) ?(limits=[]) ?(publication="stored") () =
      send (J.to_string (`Assoc ["schema",`Int 1;"publication",`String publication;
          "witness",`String input;"output",`String out;"limits",`Assoc limits])) in
    let first=job () in
    assert (field "status" first="ok");
    let digest=sha output in
    assert (field "sha256" first=digest);
    let expect code result = assert (field "code" result=code && sha output=digest) in
    expect "invalid_request" (send "{bad");
    expect "invalid_request" (job ~out:program ());
    expect "step_limit" (job ~limits:["steps",`Int 1] ());
    expect "file_limit" (job ~limits:["open_files",`Int 1] ());
    expect "memory_limit" (job ~limits:["memory_bytes",`Int 1000] ());
    expect "output_limit" (job ~limits:["output_bytes",`Int 32] ());
    expect "wall_limit" (job ~limits:["wall_ms",`Int 1] ());
    let bad_path=absolute "invalid.json" in
    Out_channel.with_open_bin bad_path (fun oc -> output_string oc "{");
    expect "invalid_input" (job ~input:bad_path ());
    let encrypted=absolute "encrypted.json" in
    J.to_file encrypted (set "os_hints_config"
      (set "public_keys" (`List [`String "0x1"]) (J.Util.member "os_hints_config" doc)) doc);
    expect "unsupported_randomized_encryption" (job ~input:encrypted ());
    let stage=absolute ".out.zip.oxcairo-worker-stage" in
    Unix.mkdir stage 0o700;
    Out_channel.with_open_bin (Filename.concat stage "out") (fun oc -> output_string oc "abandoned");
    assert (field "sha256" (job ())=digest && not (Sys.file_exists stage));
    Unix.mkdir stage 0o700;
    let foreign=Filename.concat stage "foreign" in
    Out_channel.with_open_bin foreign (fun oc -> output_string oc "retain");
    expect "io_error" (job ());
    Sys.remove foreign; Unix.rmdir stage;
    let fifo=absolute "input.fifo" in (try Unix.unlink fifo with Unix.Unix_error (ENOENT,_,_) -> ()); Unix.mkfifo fifo 0o600;
    expect "invalid_input" (job ~input:fifo ());
    Sys.remove program;
    assert (field "sha256" (job ())=digest && sha output=digest);
    let p=Pie_file.read output in
    let compressed=job ~publication:"fast-1" () in
    assert (field "status" compressed="ok" && field "sha256" compressed<>digest);
    assert (p=Pie_file.read output);
    assert (hex (Sha256.digest (Bytes.unsafe_to_string p.memory))=
      "99bfd976086c845ace970e064b0fcbcd16cd2c16772f325c0bbdd2ebe757845a")) in
  assert (status=Unix.WEXITED 0)
