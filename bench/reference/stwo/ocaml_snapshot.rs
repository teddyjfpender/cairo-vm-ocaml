use anyhow::{anyhow, ensure, Result};
use cairo_vm::{
    types::{
        builtin_name::BuiltinName,
        layout_name::LayoutName,
        relocatable::{MaybeRelocatable, Relocatable},
    },
    vm::trace::trace_entry::TraceEntry,
    Felt252,
};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::path::PathBuf;
use stwo_cairo_adapter::{
    builtins::BuiltinSegments,
    memory::{MemoryBuilder, MemoryConfig},
    opcodes::StateTransitions,
    relocator::Relocator,
    ProverInput, PublicSegmentContext,
};
use stwo_cairo_dev_utils::vm_utils::{run_and_adapt, ProgramType};

#[derive(Deserialize)]
#[serde(untagged)]
enum Cell {
    Felt(String),
    Pointer((isize, usize)),
}
#[derive(Deserialize)]
struct Snapshot {
    memory: Vec<Vec<Option<Cell>>>,
    trace: Vec<[usize; 4]>,
    builtins: BTreeMap<usize, BuiltinName>,
    public: HashMap<usize, Vec<(usize, usize)>>,
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(
        (2..=3).contains(&args.len()),
        "expected SNAPSHOT PROVER_INPUT [PROGRAM]"
    );
    let input: Snapshot = serde_json::from_reader(BufReader::new(File::open(&args[0])?))?;
    let convert = |cell: Cell| -> Result<MaybeRelocatable> {
        Ok(match cell {
            Cell::Felt(s) => Felt252::from_hex(&s)
                .map_err(|_| anyhow!("invalid snapshot felt"))?
                .into(),
            Cell::Pointer(r) => MaybeRelocatable::from(r),
        })
    };
    let mut memory = input
        .memory
        .into_iter()
        .map(|segment| {
            segment
                .into_iter()
                .map(|cell| cell.map(&convert).transpose())
                .collect()
        })
        .collect::<Result<Vec<Vec<_>>>>()?;
    let trace: Vec<TraceEntry> = input
        .trace
        .into_iter()
        .map(|[s, pc, ap, fp]| TraceEntry {
            pc: Relocatable::from((s as isize, pc)),
            ap,
            fp,
        })
        .collect();
    BuiltinSegments::pad_relocatble_builtin_segments(&mut memory, &input.builtins);
    let relocator = Relocator::new(&memory);
    let mem = MemoryBuilder::from_iter(MemoryConfig::default(), relocator.relocate_memory(&memory));
    let trace = relocator.relocate_trace(&trace);
    let state_transitions = StateTransitions::from_slice_parallel(&trace, &mem);
    let (memory, cache) = mem.build();
    let mut input = ProverInput {
        state_transitions,
        memory,
        pc_count: cache.len(),
        public_memory_addresses: relocator.relocate_public_addresses(&input.public),
        builtin_segments: relocator.relocate_builtin_segments(&input.builtins),
        public_segment_context: PublicSegmentContext::bootloader_context(),
    };
    input.public_memory_addresses.sort_unstable();
    if let Some(program) = args.get(2) {
        let mut reference = run_and_adapt(
            &PathBuf::from(program),
            ProgramType::Json,
            LayoutName::all_cairo_stwo,
            None,
        )?;
        reference.public_memory_addresses.sort_unstable();
        let got = serde_json::to_value(&input)?;
        let want = serde_json::to_value(&reference)?;
        for (name, v) in got.as_object().ok_or_else(|| anyhow!("expected object"))? {
            if &want[name] != v {
                serde_json::to_writer(File::create(format!("{}.{}.got", args[1], name))?, v)?;
                serde_json::to_writer(
                    File::create(format!("{}.{}.want", args[1], name))?,
                    &want[name],
                )?;
                anyhow::bail!("adapted field mismatch: {name}");
            }
        }
        ensure!(got == want);
    }
    let mut output = BufWriter::new(File::create(&args[1])?);
    serde_json::to_writer(&mut output, &input)?;
    output.flush()?;
    println!(
        "adapted {} OCaml steps, {} distinct instructions",
        trace.len(),
        input.pc_count
    );
    Ok(())
}
