(* -mcpu on x86 GCC only tunes scheduling. Select the ISA explicitly on x86. *)
let architecture = function
  | "amd64" | "i386" -> ["-march=native"]
  | "arm64" | "arm" -> ["-mcpu=native"]
  | _ -> []

(* Optional libdeflate and OpenSSL backends can link a system library or a
   static archive from an installation prefix. *)
let library ~variable ~name ~define ~link = function
  | "" -> []
  | "system" -> if link then ["-l" ^ name] else ["-D" ^ define]
  | prefix when Filename.is_relative prefix ->
      invalid_arg (variable ^ " must be system or an absolute installation prefix")
  | prefix ->
      if link then [Filename.concat prefix ("lib/lib" ^ name ^ ".a")]
      else ["-D" ^ define; "-I" ^ Filename.concat prefix "include"]

let libraries ~link deflate openssl =
  library ~variable:"OXC_LIBDEFLATE" ~name:"deflate" ~define:"OXC_HAVE_LIBDEFLATE" ~link deflate @
  library ~variable:"OXC_OPENSSL" ~name:"crypto" ~define:"OXC_HAVE_OPENSSL" ~link openssl

let () =
  let flags = match Array.to_list Sys.argv with
    | [_; "compile"; arch; profile; path; deflate; openssl] ->
        architecture arch @ libraries ~link:false deflate openssl @ (match profile with
        | "pgo-train" -> ["-fprofile-instr-generate"]
        | "pgo-use" when Filename.is_relative path -> failwith "OXC_PGO_PROFILE must be an absolute path"
        | "pgo-use" -> ["-fprofile-instr-use=" ^ path; "-Werror=profile-instr-out-of-date"]
        | _ -> [])
    | [_; "link"; profile; deflate; openssl] ->
        libraries ~link:true deflate openssl @ (if profile = "pgo-train" then ["-fprofile-instr-generate"] else [])
    | _ -> invalid_arg "expected compile ARCH PROFILE PATH DEFLATE OPENSSL or link PROFILE DEFLATE OPENSSL" in
  Printf.printf "(%s)\n" (String.concat " " (List.map (Printf.sprintf "%S") flags))
