// Independent Rust execution of a bootloader task, with the same unrelocated
// VM state that the Stwo adapter consumes.
mod snapshot_common;

use std::error::Error;
use std::path::PathBuf;

use cairo_program_runner_lib::types::RunMode;
use cairo_program_runner_lib::{cairo_run_program, ProgramInput};
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [program, task, snapshot] = args.as_slice() else {
        return Err("expected PROGRAM TASK SNAPSHOT".into());
    };
    let mut config = RunMode::Proof {
        layout: LayoutName::all_cairo_stwo,
        dynamic_layout_params: None,
        disable_trace_padding: true,
        relocate_mem: false,
    }
    .create_config();
    config.relocate_trace = false;
    config.fill_holes = true;
    let runner = cairo_run_program(
        &Program::from_file(program, Some("main"))?,
        Some(ProgramInput::Json(std::fs::read_to_string(task)?)),
        config,
        None,
    )?;
    snapshot_common::write(&runner, snapshot)
}
