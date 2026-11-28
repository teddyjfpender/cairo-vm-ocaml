// Independent proof-mode execution of a raw Starknet OS program and its OsHints witness.
mod snapshot_common;

use std::error::Error;
use std::fs::File;
use std::path::PathBuf;

use cairo_program_runner_lib::types::RunMode;
use cairo_vm::cairo_run::cairo_run_program;
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use starknet_os::hint_processor::panicking_state_reader::PanickingStateReader;
use starknet_os::hint_processor::snos_hint_processor::SnosHintProcessor;
use starknet_os::io::os_input::{OsHints, StarknetOsInput};

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [program, task, snapshot, kind, layout] = args.as_slice() else {
        return Err(
            "expected PROGRAM INPUT SNAPSHOT os|aggregator all_cairo|all_cairo_stwo".into(),
        );
    };
    let mut config = RunMode::Proof {
        layout: match layout.to_str() {
            Some("all_cairo") => LayoutName::all_cairo,
            Some("all_cairo_stwo") => LayoutName::all_cairo_stwo,
            _ => return Err("unrecognized proof layout".into()),
        },
        dynamic_layout_params: None,
        disable_trace_padding: true,
        relocate_mem: false,
    }
    .create_config();
    config.relocate_trace = false;
    config.fill_holes = true;
    let program = Program::from_file(program, Some("main"))?;
    let runner = if kind.to_str() == Some("aggregator") {
        use starknet_os::hint_processor::aggregator_hint_processor::AggregatorHintProcessor;
        let witness = serde_json::from_reader(std::io::BufReader::new(File::open(task)?))?;
        let mut hints = AggregatorHintProcessor::new(&program, witness);
        cairo_run_program(&program, &config, &mut hints)?
    } else if kind.to_str() == Some("os") {
        let OsHints {
            os_hints_config,
            os_input:
                StarknetOsInput {
                    os_block_inputs,
                    deprecated_compiled_classes,
                    compiled_classes,
                },
        } = serde_json::from_reader(std::io::BufReader::new(File::open(task)?))?;
        let mut hints = SnosHintProcessor::new(
            &program,
            os_hints_config,
            os_block_inputs.iter().collect(),
            deprecated_compiled_classes,
            compiled_classes,
            vec![PanickingStateReader; os_block_inputs.len()],
        )?;
        cairo_run_program(&program, &config, &mut hints)?
    } else {
        return Err("unrecognized witness kind".into());
    };
    snapshot_common::write(&runner, snapshot)
}
