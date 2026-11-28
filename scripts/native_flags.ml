(* -mcpu on x86 GCC only tunes scheduling. Select the ISA explicitly on x86. *)
let architecture mode arch = match mode, arch with
  | "x86-64", "amd64" -> ["-march=x86-64"; "-mtune=generic"]
  | "x86-64", _ -> invalid_arg "OxCairo x86-64 package requires an amd64 toolchain"
  | "", ("amd64" | "i386") -> ["-march=native"]
  | "", ("arm64" | "arm") -> ["-mcpu=native"]
  | "", _ -> []
  | _ -> invalid_arg "unsupported OXC_TARGET_CPU"

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

let pinned_archive ~link = function
  | "" -> []
  | path when Filename.is_relative path -> invalid_arg "OXC_PIE_ARCHIVE must name an absolute static library"
  | path when link -> [path]
  | _ -> ["-DOXC_HAVE_PINNED_ARCHIVE"]

let () =
  let flags = match Array.to_list Sys.argv with
    | [_; "compile"; arch; profile; path; deflate; openssl; cpu; archive] ->
        architecture cpu arch @ libraries ~link:false deflate openssl @ pinned_archive ~link:false archive @ (match profile with
        | "pgo-train" -> ["-fprofile-instr-generate"]
        | "pgo-use" when Filename.is_relative path -> failwith "OXC_PGO_PROFILE must be an absolute path"
        | "pgo-use" -> ["-fprofile-instr-use=" ^ path; "-Werror=profile-instr-out-of-date"]
        | _ -> [])
    | [_; "link"; profile; deflate; openssl; archive] ->
        libraries ~link:true deflate openssl @ pinned_archive ~link:true archive @ (if profile = "pgo-train" then ["-fprofile-instr-generate"] else [])
    | _ -> invalid_arg "expected compile ARCH PROFILE PATH DEFLATE OPENSSL CPU ARCHIVE or link PROFILE DEFLATE OPENSSL ARCHIVE" in
  Printf.printf "(%s)\n" (String.concat " " (List.map (Printf.sprintf "%S") flags))
