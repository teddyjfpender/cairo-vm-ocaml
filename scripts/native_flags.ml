(* -mcpu on x86 GCC only tunes scheduling. Select the ISA explicitly on x86. *)
let architecture = function
  | "amd64" | "i386" -> ["-march=native"]
  | "arm64" | "arm" -> ["-mcpu=native"]
  | _ -> []

let () =
  let flags = match Array.to_list Sys.argv with
    | [_; "compile"; arch; profile; path] ->
        architecture arch @ (match profile with
        | "pgo-train" -> ["-fprofile-instr-generate"]
        | "pgo-use" when Filename.is_relative path -> failwith "OXC_PGO_PROFILE must be an absolute path"
        | "pgo-use" -> ["-fprofile-instr-use=" ^ path; "-Werror=profile-instr-out-of-date"]
        | _ -> [])
    | [_; "link"; "pgo-train"] -> ["-fprofile-instr-generate"]
    | [_; "link"; _] -> []
    | _ -> invalid_arg "expected compile ARCH PROFILE PATH or link PROFILE" in
  Printf.printf "(%s)\n" (String.concat " " (List.map (Printf.sprintf "%S") flags))
