use std::error::Error;
use std::path::PathBuf;

use cairo_program_runner_lib::types::RunMode;
use cairo_program_runner_lib::{cairo_run_program, ProgramInput};
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1).map(PathBuf::from);
    let program_path = args.next().expect("compiled bootloader");
    let input_path = args.next().expect("bootloader input");
    let output_path = args.next().expect("output directory");
    let simple_bootloader_program = Program::from_file(&program_path, Some("main"))?;
    let program_input_contents = std::fs::read_to_string(input_path)?;
    let cairo_run_config = RunMode::Proof {
        layout: LayoutName::starknet_with_keccak,
        dynamic_layout_params: None,
        disable_trace_padding: false,
        relocate_mem: true,
    }
    .create_config();

    let mut runner = cairo_run_program(
        &simple_bootloader_program,
        Some(ProgramInput::Json(program_input_contents)),
        cairo_run_config,
        None,
    )?;

    let mut output_buffer = "Program Output:\n".to_string();
    runner.vm.write_output(&mut output_buffer)?;
    print!("{output_buffer}");

    use std::io::{BufWriter, Write};
    let mut trace = BufWriter::new(std::fs::File::create(output_path.join("trace.bin"))?);
    for entry in runner.relocated_trace.as_ref().unwrap() {
        for reg in [entry.ap, entry.fp, entry.pc] {
            trace.write_all(&(reg as u64).to_le_bytes())?;
        }
    }
    trace.flush()?;
    let mut memory = BufWriter::new(std::fs::File::create(output_path.join("memory.bin"))?);
    for (i, cell) in runner.relocated_memory.iter().enumerate() {
        if let Some(word) = cell {
            memory.write_all(&(i as u64).to_le_bytes())?;
            memory.write_all(&word.to_bytes_le())?;
        }
    }
    memory.flush()?;
    Ok(())
}
