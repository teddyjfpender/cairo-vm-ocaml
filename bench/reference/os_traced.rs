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
use cairo_vm::types::program::Program;
use starknet_os::hint_processor::aggregator_hint_processor::AggregatorHintProcessor;
use starknet_os::hint_processor::panicking_state_reader::PanickingStateReader;
use starknet_os::hint_processor::snos_hint_processor::SnosHintProcessor;
use starknet_os::io::os_input::{OsHints, StarknetOsInput};
use starknet_os::runner::DEFAULT_OS_LAYOUT;

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let (kind, source, directory, proof_program) = match args.as_slice() {
        [kind, source, directory] => (kind, source, directory, None),
        [kind, source, directory, flag, path] if flag == "--proof-program" => (
            kind,
            source,
            directory,
            Some(Program::from_file(Path::new(path), Some("main"))?),
        ),
        _ => return Err(
            "expected os|virtual-os|aggregator WITNESS ARTIFACT_DIRECTORY [--proof-program FILE]"
                .into(),
        ),
    };
    let proof = proof_program.is_some();
    let config = CairoRunConfig {
        layout: DEFAULT_OS_LAYOUT,
        trace_enabled: true,
        proof_mode: proof,
        fill_holes: proof,
        relocate_trace: true,
        relocate_mem: true,
        ..Default::default()
    };
    let input = BufReader::new(File::open(source)?);
    let mut runner = match kind.as_str() {
        "os" | "virtual-os" => {
            let program = proof_program.as_ref().unwrap_or_else(|| {
                if kind == "os" {
                    &OS_PROGRAM
                } else {
                    &VIRTUAL_OS_PROGRAM
                }
            });
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
            let program = proof_program.as_ref().unwrap_or(&AGGREGATOR_PROGRAM);
            let mut hints = AggregatorHintProcessor::new(program, serde_json::from_reader(input)?);
            cairo_run_program(program, &config, &mut hints)?
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
    if proof {
        let directory = directory.canonicalize()?;
        let private = runner.get_air_private_input().to_serializable(
            directory.join("trace.bin").to_string_lossy().into_owned(),
            directory.join("memory.bin").to_string_lossy().into_owned(),
        );
        std::fs::write(
            directory.join("air-public.json"),
            runner.get_air_public_input()?.serialize_json()?,
        )?;
        std::fs::write(
            directory.join("air-private.json"),
            private.serialize_json()?,
        )?;
    }
    Ok(())
}
