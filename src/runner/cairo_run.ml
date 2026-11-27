type config = Runner.config
type result = Runner.t

let default_config = {
  Runner.layout = "plain"; trace = false; secure_run = true;
  allow_missing_builtins = false; entrypoint = "main";
}

let run ?(config=default_config) ?(fill_holes=false) program =
  let runner = Runner.initialize config program in
  Runner.run_until_end runner;
  Runner.end_run ~fill_holes runner ~secure:config.secure_run
    ~allow_missing:config.allow_missing_builtins;
  runner

let run_file ?config ?fill_holes file =
  run ?config ?fill_holes (Program.load_file file)
