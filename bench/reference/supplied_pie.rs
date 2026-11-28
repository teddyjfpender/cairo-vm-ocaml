// Benchmark adapter for the pinned sequencer. Keep its real stateless SNOS
// entry point, embedded program and process alive across independently read jobs.
use apollo_starknet_os_program::OS_PROGRAM;
use cairo_vm::vm::runners::cairo_pie::CairoPie;
use serde_json::json;
use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{DEFAULT_OS_LAYOUT, run_os_stateless};
use std::error::Error;
use std::fs::File;
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::time::Instant;
use zip::{CompressionMethod, ZipWriter, write::FileOptions};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn write_stored(pie: &CairoPie, path: &Path) -> Result<()> {
    let mut out = ZipWriter::new(io::BufWriter::new(File::create(path)?));
    let options = FileOptions::default().compression_method(CompressionMethod::Stored);
    out.start_file("version.json", options)?;
    serde_json::to_writer(&mut out, &pie.version)?;
    out.start_file("metadata.json", options)?;
    serde_json::to_writer(&mut out, &pie.metadata)?;
    out.start_file("memory.bin", options)?;
    out.write_all(&pie.memory.to_bytes(None))?;
    out.start_file("additional_data.json", options)?;
    serde_json::to_writer(&mut out, &pie.additional_data)?;
    out.start_file("execution_resources.json", options)?;
    serde_json::to_writer(&mut out, &pie.execution_resources)?;
    out.finish()?.flush()?;
    Ok(())
}

fn run(input: &Path, output: &Path, stored: bool) -> Result<()> {
    let start = Instant::now();
    let bytes = std::fs::read(input)?;
    let hints: OsHints = serde_json::from_slice(&bytes)?;
    drop(bytes);
    let decoded = Instant::now();
    let result = run_os_stateless(DEFAULT_OS_LAYOUT, hints)?;
    let executed = Instant::now();
    if stored {
        write_stored(&result.cairo_pie, output)?;
    } else {
        result.cairo_pie.write_zip_file(output, false)?;
    }
    drop(result);
    let end = Instant::now();
    println!(
        "{}",
        json!({
            "decode_s": (decoded-start).as_secs_f64(),
            "run_and_extract_s": (executed-decoded).as_secs_f64(),
            "store_and_drop_s": (end-executed).as_secs_f64(),
            "total_s": (end-start).as_secs_f64()
        })
    );
    Ok(())
}

fn main() -> Result<()> {
    let stored = match std::env::args().nth(1).as_deref() {
        Some("stored") => true,
        Some("standard") => false,
        _ => return Err("usage: supplied_pie stored|standard".into()),
    };
    let start = Instant::now();
    std::sync::LazyLock::force(&OS_PROGRAM);
    println!(
        "{}",
        json!({"compiler_prepare_s":start.elapsed().as_secs_f64()})
    );
    io::stdout().flush()?;
    for command in io::stdin().lock().lines() {
        let command = command?;
        let (witness, output) = command
            .split_once('\t')
            .ok_or("expected WITNESS<TAB>OUTPUT")?;
        run(Path::new(witness), Path::new(output), stored)?;
        io::stdout().flush()?;
    }
    Ok(())
}
