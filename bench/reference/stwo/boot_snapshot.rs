// Independent Rust execution of a bootloader task, with the same unrelocated
// VM state that the Stwo adapter consumes.
use std::error::Error;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

use cairo_program_runner_lib::types::RunMode;
use cairo_program_runner_lib::{cairo_run_program, ProgramInput};
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use cairo_vm::types::relocatable::MaybeRelocatable;
use serde::Serialize;

#[derive(Serialize)]
#[serde(untagged)]
enum Cell {
    Felt(String),
    Pointer((isize, usize)),
}

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
    let memory: Vec<Vec<Option<Cell>>> = runner
        .get_relocatable_memory()
        .into_iter()
        .map(|segment| {
            segment
                .into_iter()
                .map(|cell| {
                    cell.map(|v| match v {
                        MaybeRelocatable::Int(felt) => Cell::Felt(format!("{felt:#x}")),
                        MaybeRelocatable::RelocatableValue(p) => {
                            Cell::Pointer((p.segment_index, p.offset))
                        }
                    })
                })
                .collect()
        })
        .collect();
    let trace: Vec<_> = runner
        .get_relocatable_trace()?
        .iter()
        .map(|row| (row.pc.segment_index, row.pc.offset, row.ap, row.fp))
        .collect();
    let mut output = BufWriter::new(File::create(snapshot)?);
    serde_json::to_writer(
        &mut output,
        &serde_json::json!({
            "memory": memory, "trace": trace, "builtins": runner.get_builtin_segments(),
            "public": runner.vm.segments.public_memory_offsets
        }),
    )?;
    output.flush()?;
    Ok(())
}
