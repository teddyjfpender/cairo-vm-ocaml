// A traced CairoRunner with the pinned sequencer's native hint processors.
// Install as an example of starknet_os with the deserialize and testing features.
use std::error::Error;
use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use apollo_starknet_os_program::{AGGREGATOR_PROGRAM, OS_PROGRAM, VIRTUAL_OS_PROGRAM};
use cairo_vm::cairo_run::{
    cairo_run_program, write_encoded_memory, write_encoded_trace, CairoRunConfig,
};
use starknet_os::hint_processor::aggregator_hint_processor::AggregatorHintProcessor;
use starknet_os::hint_processor::panicking_state_reader::PanickingStateReader;
use starknet_os::hint_processor::snos_hint_processor::SnosHintProcessor;
use starknet_os::io::os_input::{OsHints, StarknetOsInput};
use starknet_os::runner::DEFAULT_OS_LAYOUT;

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let [kind, source, directory] = args.as_slice() else {
        return Err("expected os|virtual-os|aggregator WITNESS ARTIFACT_DIRECTORY".into());
    };
    let config = CairoRunConfig {
        layout: DEFAULT_OS_LAYOUT,
        trace_enabled: true,
        relocate_trace: true,
        relocate_mem: true,
        ..Default::default()
    };
    let input = BufReader::new(File::open(source)?);
    let mut runner = match kind.as_str() {
        "os" | "virtual-os" => {
            let program = if kind == "os" {
                &OS_PROGRAM
            } else {
                &VIRTUAL_OS_PROGRAM
            };
            let OsHints {
                os_hints_config,
                os_input:
                    StarknetOsInput {
                        os_block_inputs,
                        deprecated_compiled_classes,
                        compiled_classes,
                    },
            } = serde_json::from_reader(input)?;
            let mut hints = SnosHintProcessor::new(
                program,
                os_hints_config,
                os_block_inputs.iter().collect(),
                deprecated_compiled_classes,
                compiled_classes,
                vec![PanickingStateReader; os_block_inputs.len()],
            )?;
            cairo_run_program(program, &config, &mut hints)?
        }
        "aggregator" => {
            let mut hints =
                AggregatorHintProcessor::new(&AGGREGATOR_PROGRAM, serde_json::from_reader(input)?);
            cairo_run_program(&AGGREGATOR_PROGRAM, &config, &mut hints)?
        }
        _ => return Err("unknown witness kind".into()),
    };
    let mut stdout = String::from("Program Output:\n");
    runner.vm.write_output(&mut stdout)?;
    print!("{stdout}");

    let directory = Path::new(directory);
    let mut trace = BufWriter::new(File::create(directory.join("trace.bin"))?);
    write_encoded_trace(
        runner.relocated_trace.as_deref().ok_or("missing trace")?,
        &mut trace,
    )?;
    trace.flush()?;
    let mut memory = BufWriter::new(File::create(directory.join("memory.bin"))?);
    write_encoded_memory(&runner.relocated_memory, &mut memory)?;
    memory.flush()?;
    Ok(())
}
