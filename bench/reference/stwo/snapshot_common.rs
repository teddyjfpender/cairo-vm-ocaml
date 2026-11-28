// Shared snapshot representation for the independent sequencer references.
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

use cairo_vm::types::relocatable::MaybeRelocatable;
use cairo_vm::vm::runners::cairo_runner::CairoRunner;
use serde::Serialize;

#[derive(Serialize)]
#[serde(untagged)]
enum Cell {
    Felt(String),
    Pointer((isize, usize)),
}

pub fn write(runner: &CairoRunner, snapshot: &Path) -> Result<(), Box<dyn std::error::Error>> {
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
