(* Profiling aid: run one program N times in-process so samplers see enough
   of a short run.  usage: repeat.exe PROGRAM.json N [LAYOUT] *)
open Cairovm

let () =
  let program = Program.load_file Sys.argv.(1) and n = int_of_string Sys.argv.(2) in
  let layout = if Array.length Sys.argv > 3 then Sys.argv.(3) else "all_cairo" in
  let config = { Cairo_run.default_config with layout } in
  let t = Unix.gettimeofday () in
  for _ = 1 to n do ignore (Cairo_run.run ~config program) done;
  Printf.printf "%d runs, %.3f s/run\n" n ((Unix.gettimeofday () -. t) /. float n)
