let path = function "" -> None | p -> Some p

let replay input layout trace memory output =
  try
    Cairovm.Pie_run.replay_file ~layout ?trace:(path trace) ?memory:(path memory)
      ?output:(path output) input;
    ""
  with ex -> Printexc.to_string ex

let () = Callback.register "oxcairo.replay.v1" replay
