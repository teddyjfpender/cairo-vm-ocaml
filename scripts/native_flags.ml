(* -mcpu on x86 GCC only tunes scheduling. Select the host ISA explicitly
   on x86 builds, retaining the original flag on ARM. *)
let () =
  print_endline (match Sys.argv.(1) with
    | "amd64" | "i386" -> "(-march=native)"
    | "arm64" | "arm" -> "(-mcpu=native)"
    | _ -> "()")
