// Install as an example of starknet_os in the pinned sequencer checkout.
use apollo_starknet_os_program::OS_PROGRAM;
use cairo_vm::cairo_run::CairoRunConfig;
use cairo_vm::vm::runners::cairo_runner::CairoRunner;
use starknet_os::hint_processor::panicking_state_reader::PanickingStateReader;
use starknet_os::hint_processor::snos_hint_processor::SnosHintProcessor;
use starknet_os::io::os_input::{OsHints, StarknetOsInput};
use starknet_os::io::os_output::get_run_output;
use starknet_os::runner::DEFAULT_OS_LAYOUT;
use std::fs::File;
use std::io::BufReader;

fn main() {
    let mut args = std::env::args_os().skip(1);
    let input = BufReader::new(File::open(args.next().expect("OS input")).unwrap());
    let OsHints {
        os_hints_config,
        os_input:
            StarknetOsInput {
                os_block_inputs,
                deprecated_compiled_classes,
                compiled_classes,
            },
    } = serde_json::from_reader(input).unwrap();
    let mut hints = SnosHintProcessor::new(
        &OS_PROGRAM,
        os_hints_config,
        os_block_inputs.iter().collect(),
        deprecated_compiled_classes,
        compiled_classes,
        vec![PanickingStateReader; os_block_inputs.len()],
    )
    .unwrap();
    let config = CairoRunConfig {
        layout: DEFAULT_OS_LAYOUT,
        ..Default::default()
    };
    let missing = config.allow_missing_builtins.unwrap_or(false);
    let mut runner = CairoRunner::new(
        &OS_PROGRAM,
        config.layout,
        config.dynamic_layout_params,
        config.proof_mode,
        config.trace_enabled,
        config.disable_trace_padding,
    )
    .unwrap();
    let end = runner.initialize(missing).unwrap();
    runner.run_until_pc(end, &mut hints).unwrap();
    runner
        .end_run(
            config.disable_trace_padding,
            false,
            &mut hints,
            config.fill_holes,
        )
        .unwrap();
    let output = get_run_output(&runner.vm).unwrap();
    runner.vm.verify_auto_deductions().unwrap();
    runner.read_return_values(missing).unwrap();

    #[cfg(feature = "oxcairo_stream")]
    if let Some(archive) = args.next() {
        runner.vm.segments.compute_effective_sizes();
        let pie = runner.oxcairo_build_pie(false).unwrap();
        pie.oxcairo_write_stream(
            std::path::Path::new(&archive),
            true,
            Some(&runner.vm.segments.memory),
        )
        .unwrap();
    }
    assert!(args.next().is_none(), "unexpected arguments");
    for word in output {
        println!("{word:#x}");
    }
}
